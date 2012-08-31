require 'rubygems'
require 'sinatra/base'
require 'sinatra/mustache'
require 'sinatra/json'
require 'sinatra/reloader'
require 'mongo'
require 'json'
require 'uri'

class Genghis < Sinatra::Base
  enable :inline_templates
  register Sinatra::Reloader if development?

  class GenghisJson
    class << self
      def encode(object)
        enc(object, Array, Hash, BSON::OrderedHash).to_json
      end

      def decode(str)
        dec(JSON.parse(str))
      end

      private

      def enc(o, *a)
        o = o.to_s if o.is_a? Symbol
        fail "invalid: #{o.inspect}" unless a.empty? or a.include? o.class
        case o
        when Array then o.map { |e| enc(e) }
        when Hash then o.merge(o) { |k, v| enc(v) }
        when Time then thunk('ISODate', o.strftime('%FT%T%:z'))
        when Regexp then thunk('RegExp', {'$pattern' => o.source, '$flags' => enc_re_flags(o.options)})
        when BSON::ObjectId then thunk('ObjectId', o.to_s)
        when BSON::DBRef then db_ref(o)
        else o
        end
      end

      def thunk(name, value)
        {'$genghisType' => name, '$value' => value }
      end

      def enc_re_flags(opt)
        (opt & Regexp::MULTILINE ? 'm' : '') + (opt & Regexp::IGNORECASE ? 'i' : '')
      end

      def db_ref(o)
        o = o.to_hash
        {'$ref' => o['$ns'], '$id' => enc(o['$id'])}
      end

      def dec(o)
        case o
        when Array then o.map { |e| dec(e) }
        when Hash then
          case o['$genghisType']
          when 'ObjectId' then BSON::ObjectId.from_string(o['$value'])
          when 'ISODate' then DateTime.parse(o['$value']).to_time
          when 'RegExp' then Regexp.new(o['$value']['$pattern'], dec_re_flags(o['$value']['$flags']))
          else o.merge(o) { |k, v| dec(v) }
          end
        else o
        end
      end

      def dec_re_flags(flags)
        (flags.include?('m') ? Regexp::MULTILINE : 0) | (flags.include?('i') ? Regexp::IGNORECASE : 0)
      end
    end
  end

  helpers Sinatra::JSON
  set :json_encoder, GenghisJson
  set :json_content_type, :json

  def connection(server_name)
    server = @servers[server_name]

    if server.start_with?('mongodb://')
      Mongo::Connection.from_uri(server)
    else
      host, port = @servers[server_name].split(':')
      Mongo::Connection.new(host, port ? port.to_i : 27017)
    end
  end

  def server_info(server_name)
    # TODO: not all are editable... remove "editable: true" once default servers are implemented
    resp = { :id => server_name, :name => server_name, :editable => true }
    begin
      conn = connection(server_name)
    rescue Mongo::ConnectionFailure => ex
      resp.merge!({ :error => ex.to_s })
    else
      databases = conn['admin'].command({:listDatabases => true})
      resp.merge!({
        :size => databases['totalSize'],
        :count => databases['databases'].count,
        :databases => databases['databases'].map {|db| db['name']}
      })
    end
  end

  def database_info(server_name, database)
    conn = connection(server_name)
    collections = conn[database['name']].collections
    collections.reject! {|collection| collection.name.start_with?('system')}
    {
      :id => database['name'],
      :name => database['name'],
      :size => database['sizeOnDisk'],
      :count => collections.count,
      :collections => collections.map {|collection| collection.name}
    }
  end

  def collection_info(collection)
    {
      :id => collection.name,
      :name => collection.name,
      :count => collection.count,
      :indexes => collection.index_information.values
    }
  end

  def document_info(collection, page)
    {
      :count => collection.count,
      :page => page,
      :pages => 1,
      :per_page => 50,
      :offset => 50,
      :documents => collection.find(
        {},
        :limit => 50,
        :skip => 50 * (page - 1)
      ).to_a
    }
  end

  def thunk_mongo_id(id)
    id =~ /^[a-f0-9]{24}$/i ? BSON::ObjectId(id) : id
  end

  before do
    @servers ||= { 'localhost' => 'localhost:27017' }
    if servers = request.cookies['genghis_rb_servers']
      @servers = JSON.parse(servers)
    end
  end

  get '/check-status' do
    json({:alerts => []})
  end

  get '/assets/style.css' do
    content_type 'text/css'
    Genghis.templates['style.css'.intern].first
  end

  get '/assets/script.js' do
    content_type 'text/javascript'
    Genghis.templates['script.js'.intern].first
  end

  get '*' do
    if request.xhr?
      pass
    else
      mustache 'index.html.mustache'.intern
    end
  end

  get '/servers' do
    json @servers.keys.collect {|server_name| server_info(server_name)}
  end

  post '/servers' do
    name = JSON.parse(request.body.read)['name']
    @servers[name] = name
    response.set_cookie(
      :genghis_rb_servers,
      :path => '/',
      :value => JSON.dump(@servers),
      :expires => Time.now + 60*60*24*365
    )
    json server_info(name)
  end

  delete '/servers/:server' do
    @servers.delete(params[:server])
    response.set_cookie(
      :genghis_rb_servers,
      :path => '/',
      :value => JSON.dump(@servers),
      :expires => Time.now + 60*60*24*365
    )
    json({ :success => true })
  end

  get '/servers/:server' do |server|
    json server_info(server)
  end

  get '/servers/:server/databases' do |server|
    databases = connection(server)['admin'].command({:listDatabases => true})['databases']
    json databases.map {|database| database_info(server, database)}
  end

  get '/servers/:server/databases/:database' do |server, db|
    databases = connection(server)['admin'].command({:listDatabases => true})['databases']
    database  = databases.detect {|d| d['name'] == db}
    json database_info(server, database)
  end

  get '/servers/:server/databases/:database/collections' do |server, db|
    database = connection(server)[db]
    collections = database.collections.reject {|collection| collection.name.start_with?('system')}
    json collections.map {|collection| collection_info(collection)}
  end

  get '/servers/:server/databases/:database/collections/:collection' do |server, db, coll|
    collection = connection(server)[db][coll]
    json collection_info(collection)
  end

  get '/servers/:server/databases/:database/collections/:collection/documents' do |server, db, coll|
    collection = connection(server)[db][coll]
    page = params.fetch(:page, 1).to_i
    json document_info(collection, page)
  end

  get '/servers/:server/databases/:database/collections/:collection/documents/:document' do |server, db, coll, doc|
    document = connection(server)[db][coll].find_one('_id' => thunk_mongo_id(doc))
    json document
  end

  put '/servers/:server/databases/:database/collections/:collection/documents/:document' do |server, db, coll, doc|
    data = GenghisJson.decode(request.body.read)

    document = connection(server)[db][coll].find_and_modify \
      :query => {'_id' => thunk_mongo_id(doc)},
      :update => data,
      :new => true

    json document
  end
end

Genghis.run!