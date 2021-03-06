# -*- coding: utf-8 -*-                
require 'rubygems'
require 'active_support/core_ext/module/aliasing'
require 'active_record' unless defined?(ActiveRecord)
# require 'mysql2' #0.2.7      
# require 'active_record/connection_adapters/mysql2_adapter'
require 'meta_where' unless defined?(MetaWhere)
#require 'composite_primary_keys'

require 'rufus/json'
require 'ruote/storage/base'
Rufus::Json.backend = :active_support

#resolve sequel + meta_where conflict
module MetaWhere
  class Column
    def sql_literal(opts)
      "#{@column}"
    end
  end
end

unless DateTime.instance_methods.include?(:usec)
  class DateTime
    def usec
      0
    end
  end
end



#Deixando mais robusto, para multi thread worker
class << Thread
  alias orig_new new
  def new
    orig_new do
      begin
        yield
      ensure
        ActiveRecord::Base.connection_pool.release_connection if ActiveRecord::Base.connection_pool
      end
    end
  end
end                

# module ActiveRecord::ConnectionAdapters
#   class Mysql2Adapter
#       alias_method :execute_without_retry, :execute
#       def execute(*args)
#         retries = 3
#         begin
#           execute_without_retry(*args)
#         rescue ActiveRecord::StatementInvalid
#           if $!.message =~ /server has gone away/i || $!.message =~ /lost connection to mysql/i ||
#               $!.message =~ /is still waiting for a result/i
#             
#             Rails.logger.warn "Server timed out, retrying. #{retries} left."
#             reconnect!
#             retry if (retries -= 1) > 0
#           end
#           raise
#         end
#     end
#   end
# end

module Ruote
  module ActiveRecord
    
    class Document < ::ActiveRecord::Base
      set_table_name :documents
      #set_primary_key :typ, :ide, :rev
      
      
      def self.before_fork
        ::ActiveRecord::Base.clear_all_connections!
      end

      def self.after_fork
        ::ActiveRecord::Base.establish_connection
      end
      
      def to_h
        Rufus::Json.decode(doc)
      end

      def to_wi
        Ruote::Workitem.from_json(doc)
      end
      
      def <=>(other)
        self.ide <=> other.ide
      end
    end
    
    
    
    class Storage
      include Ruote::StorageBase


      def initialize(options = {})
        @options = options
        put_configuration
      end      
      
      
      def put_msg(action, options)

        # put_msg is a unique action, no need for all the complexity of put

        do_insert(prepare_msg_doc(action, options), 1)

        nil
      end

      def put_schedule(flavour, owner_fei, s, msg)

        # put_schedule is a unique action, no need for all the complexity of put

        doc = prepare_schedule_doc(flavour, owner_fei, s, msg)

        return nil unless doc

        do_insert(doc, 1)

        doc['_id']
      end

      def put(doc, opts={})

        nrev = doc['_rev'].to_i + 1
        
        begin
          
          if doc['_rev']                 
              
            Document.transaction do
              current = Document.where(:typ => doc['type'], :ide => doc['_id'], :rev => doc['_rev']).lock(true).first
              
              d = get(doc['type'], doc['_id'])             
              
              return true unless d
              return d if d['_rev'] != doc['_rev']
              return d if current.nil?
                                                                       
              json = Rufus::Json.encode(doc.merge('_rev' => nrev, 'put_at' => Ruote.now_to_utc_s))
              
              # st = Document.execute_sql([
              #       'update documents set rev=rev+1, wfid=?, doc=?, participant_name=? where typ=? and ide=? and rev=?',
              #       extract_wfid(doc),
              #       doc['participant_name'],
              #       doc['type'],
              #       doc['_id'],
              #       doc['_rev']
              #     ])
              
              #json = Document.connection.raw_connection.escape(json)
              #json = json.gsub(/\\/, '\&\&').gsub(/'/, "''")
              json = Document.connection.quote_string(json)
              
              
              sql = "update documents set rev=rev+1, wfid='#{extract_wfid(doc)}', doc='#{json}', participant_name='#{doc['participant_name']}' where typ='#{doc['type']}' and ide='#{doc['_id']}' and rev=#{doc['_rev']}"
              st = Document.connection.execute(sql)                                          
                     
            end
            
            
          else             
            do_insert(doc, nrev)
          end
          

        rescue Exception => de
          puts "Error putting: #{de.message}: #{doc.inspect}"
          puts de.backtrace

          return (get(doc['type'], doc['_id']) || true)
          # failure
        end


        doc['_rev'] = nrev if opts[:update_rev]

        nil
        # success
      end

      def get(type, key)

        d = do_get(type, key)

        d ? d.to_h : nil
      end

      def delete(doc)
        return if doc.nil?
        raise ArgumentError.new('no _rev for doc') unless doc['_rev']

        count = do_delete(doc)

        return (get(doc['type'], doc['_id']) || true) if count < 1
        # failure

        nil
        # success
      end

      def get_many(type, key=nil, opts={})

        ds = Document.where(:typ => type)

        keys = key ? Array(key) : nil
        ds = ds.where(:wfid => keys) if keys && keys.first.is_a?(String)

        return ds.all.size if opts[:count]

        ds = ds.order(
                      *(opts[:descending] ? [ :ide.desc, :rev.desc ] : [ :ide.asc, :rev.asc ])
                      )

        ds = ds.limit(opts[:limit]).offset(opts[:skip])

        docs = ds.all
        docs = select_last_revs(docs, opts[:descending])
        docs = docs.collect { |d| Rufus::Json.decode(d[:doc]) }

        keys && keys.first.is_a?(Regexp) ?
        docs.select { |doc| keys.find { |key| key.match(doc['_id']) } } :
          docs

        # (pass on the dataset.filter(:wfid => /regexp/) for now
        # since we have potentially multiple keys)
      end

      # Returns all the ids of the documents of a given type.
      #
      def ids(type)
        Document.where(:typ => type).select(:ide).order(:ide.asc).collect { |d| d[:ide] }.uniq
      end

      # Nukes all the documents in this storage.
      #
      def purge!
        Document.delete_all
      end

      # Returns a string representation the current content of the storage for
      # a given type.
      #
      def dump(type)

        "=== #{type} ===\n" +
          get_many(type).map { |h| "  #{h['_id']} => #{h.inspect}" }.join("\n")
      end

      # Calls #disconnect on the db. According to Sequel's doc, it closes
      # all the idle connections in the pool (not the active ones).
      #
      def shutdown
        #Ruote::ActiveRecord::Document.before_fork
      end

      # Grrr... I should sort the mess between close and shutdown...
      # Tests vs production :-(
      #
      def close
        #Ruote::ActiveRecord::Document.before_fork
      end

      # Mainly used by ruote's test/unit/ut_17_storage.rb
      #
      def add_type(type)

        # does nothing, types are differentiated by the 'typ' column
      end

      # Nukes a db type and reputs it (losing all the documents that were in it).
      #
      def purge_type!(type)
        Document.delete(:typ => type)
      end

      # A provision made for workitems, allow to query them directly by
      # participant name.
      #
      def by_participant(type, participant_name, opts)

        raise NotImplementedError if type != 'workitems'

        docs = Document.where(
                              :typ => type, :participant_name => participant_name
                              ).limit(opts[:limit]).offset(opts[:offset] || opts[:skip])

        docs = select_last_revs(docs)

        opts[:count] ?
        docs.size :
          docs.collect { |d| d.to_h }
      end

      # Querying workitems by field (warning, goes deep into the JSON structure)
      #
      def by_field(type, field, value, opts = {})

        raise NotImplementedError if type != 'workitems'

        lk = [ '%"', field, '":' ]
        lk.push(Rufus::Json.encode(value)) if value
        lk.push('%')

        docs = Document.where(:typ => type, :doc.matches => lk.join)
        docs = docs.limit(opts[:limit]).offset(opts[:skip] || opts[:offset])
        docs = select_last_revs(docs)

        opts[:count] ?
        docs.size :
          docs.map { |d| d.to_h }
      end

      def query_workitems(criteria)

        ds = Document.where(:typ => 'workitems')

        count = criteria.delete('count')
        limit = criteria.delete('limit')
        offset = criteria.delete('offset') || criteria.delete('skip')

        ds = ds.limit(limit).offset(offset)

        wfid =
          criteria.delete('wfid')
        pname =
          criteria.delete('participant_name') || criteria.delete('participant')

        ds = ds.where(:ide.matches => "%!#{wfid}") if wfid
        ds = ds.where(:participant_name => pname) if pname

        criteria.collect do |k, v|
          ds = ds.where(:doc.matches => "%\"#{k}\":#{Rufus::Json.encode(v)}%")
        end

        ds = select_last_revs(ds.all)

        count ? ds.size : ds.collect { |d| d.to_wi }
      end

      
      
      protected

      def do_delete(doc)

        count = Document.delete_all(
                                    :ide => doc['_id'], :typ => doc['type'], :rev => doc['_rev'].to_i
                                    )
        
        count
      end

      def do_insert(doc, rev)

        Document.create!(
                         :ide => doc['_id'],
                         :rev => rev,
                         :typ => doc['type'],
                         :doc => Rufus::Json.encode(doc.merge(
                                                              '_rev' => rev,
                                                              'put_at' => Ruote.now_to_utc_s)),
                         :wfid => extract_wfid(doc),
                         :participant_name => doc['participant_name']
                         )
      end

      def extract_wfid(doc)

        doc['wfid'] || (doc['fei'] ? doc['fei']['wfid'] : nil)
      end

      def do_get(type, key)

        Document.where(
                       :typ => type, :ide => key
                       ).order(:rev.desc).first
      end

      # Don't put configuration if it's already in
      #
      # (avoid storages from trashing configuration...)
      #
      def put_configuration

        return if get('configurations', 'engine')

        conf = { '_id' => 'engine', 'type' => 'configurations' }.merge(@options)
        put(conf)
      end

      def select_last_revs(docs, reverse=false)
        docs = docs.inject({}) { |h, doc| h[doc.ide] = doc; h }.values.sort
        reverse ? docs.reverse : docs
      end
      
    end
    
  end
end
