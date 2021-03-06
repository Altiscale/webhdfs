require 'net/http'
require 'uri'
require 'json'
require 'addressable/uri'

require_relative 'exceptions'

module WebHDFS
  class ClientV1

    # This hash table holds command options.
    OPT_TABLE = {} # internal use only
    KNOWN_ERRORS = ['LeaseExpiredException'].freeze

    attr_accessor :host, :port, :username, :doas, :proxy_address, :proxy_port
    attr_accessor :proxy_user, :proxy_pass
    attr_accessor :open_timeout # default 30s (in ruby net/http)
    attr_accessor :read_timeout # default 60s (in ruby net/http)
    attr_accessor :httpfs_mode
    attr_accessor :retry_known_errors # default false (not to retry)
    attr_accessor :retry_times        # default 1 (ignored when retry_known_errors is false)
    attr_accessor :retry_interval     # default 1 ([sec], ignored when retry_known_errors is false)
    attr_accessor :reuse_connection   # default false (do not try to reuse HTTP connection)
    attr_accessor :ssl
    attr_accessor :ssl_ca_file
    attr_reader   :ssl_verify_mode
    attr_accessor :kerberos, :kerberos_keytab

    SSL_VERIFY_MODES = [:none, :peer]
    def ssl_verify_mode=(mode)
      unless SSL_VERIFY_MODES.include? mode
        raise ArgumentError, "Invalid SSL verify mode #{mode.inspect}"
      end
      @ssl_verify_mode = mode
    end

    def initialize(host='localhost', port=50070, username=nil, doas=nil, proxy_address=nil, proxy_port=nil)
      @host = host
      @port = port
      @username = username
      @doas = doas
      @proxy_address = proxy_address
      @proxy_port = proxy_port
      @retry_known_errors = false
      @retry_times = 1
      @retry_interval = 1

      @httpfs_mode = false

      @ssl = false
      @ssl_ca_file = nil
      @ssl_verify_mode = nil

      @kerberos = false
      @kerberos_keytab = nil
      @reuse_connection = false
      @connection = nil
    end

    # curl -i -X PUT "http://<HOST>:<PORT>/webhdfs/v1/<PATH>?op=CREATE
    #                 [&overwrite=<true|false>][&blocksize=<LONG>][&replication=<SHORT>]
    #                 [&permission=<OCTAL>][&buffersize=<INT>]"
    def create(path, body, options={})
      if @httpfs_mode
        options = options.merge({'data' => 'true'})
      end
      check_options(options, OPT_TABLE['CREATE'])
      res = operate_requests('PUT', path, 'CREATE', options, body)
      res.code == '201'
    end
    OPT_TABLE['CREATE'] = ['overwrite', 'blocksize', 'replication', 'permission', 'buffersize', 'data']

    # curl -i -X POST "http://<HOST>:<PORT>/webhdfs/v1/<PATH>?op=APPEND[&buffersize=<INT>]"
    def append(path, body, options={})
      if @httpfs_mode
        options = options.merge({'data' => 'true'})
      end
      check_options(options, OPT_TABLE['APPEND'])
      res = operate_requests('POST', path, 'APPEND', options, body)
      res.code == '200'
    end
    OPT_TABLE['APPEND'] = ['buffersize', 'data']

    # curl -i -L "http://<HOST>:<PORT>/webhdfs/v1/<PATH>?op=OPEN
    #                [&offset=<LONG>][&length=<LONG>][&buffersize=<INT>]"
    def read(path, options={})
      check_options(options, OPT_TABLE['OPEN'])
      res = operate_requests('GET', path, 'OPEN', options)
      res.body
    end
    OPT_TABLE['OPEN'] = ['offset', 'length', 'buffersize']
    alias :open :read

    # curl -i -X PUT "http://<HOST>:<PORT>/<PATH>?op=MKDIRS[&permission=<OCTAL>]"
    def mkdir(path, options={})
      check_options(options, OPT_TABLE['MKDIRS'])
      res = operate_requests('PUT', path, 'MKDIRS', options)
      check_success_json(res, 'boolean')
    end
    OPT_TABLE['MKDIRS'] = ['permission']
    alias :mkdirs :mkdir

    # curl -i -X PUT "<HOST>:<PORT>/webhdfs/v1/<PATH>?op=RENAME&destination=<PATH>"
    def rename(path, dest, options={})
      check_options(options, OPT_TABLE['RENAME'])
      unless dest.start_with?('/')
        dest = '/' + dest
      end
      res = operate_requests('PUT', path, 'RENAME', options.merge({'destination' => dest}))
      check_success_json(res, 'boolean')
    end

    # curl -i -X DELETE "http://<host>:<port>/webhdfs/v1/<path>?op=DELETE
    #                          [&recursive=<true|false>]"
    def delete(path, options={})
      check_options(options, OPT_TABLE['DELETE'])
      res = operate_requests('DELETE', path, 'DELETE', options)
      check_success_json(res, 'boolean')
    end
    OPT_TABLE['DELETE'] = ['recursive']

    # curl -i  "http://<HOST>:<PORT>/webhdfs/v1/<PATH>?op=GETFILESTATUS"
    def stat(path, options={})
      check_options(options, OPT_TABLE['GETFILESTATUS'])
      res = operate_requests('GET', path, 'GETFILESTATUS', options)
      check_success_json(res, 'FileStatus')
    end
    alias :getfilestatus :stat

    # curl -i  "http://<HOST>:<PORT>/webhdfs/v1/<PATH>?op=LISTSTATUS"
    def list(path, options={})
      check_options(options, OPT_TABLE['LISTSTATUS'])
      res = operate_requests('GET', path, 'LISTSTATUS', options)
      check_success_json(res, 'FileStatuses')['FileStatus']
    end
    alias :liststatus :list

    # curl -i "http://<HOST>:<PORT>/webhdfs/v1/<PATH>?op=GETCONTENTSUMMARY"
    def content_summary(path, options={})
      check_options(options, OPT_TABLE['GETCONTENTSUMMARY'])
      res = operate_requests('GET', path, 'GETCONTENTSUMMARY', options)
      check_success_json(res, 'ContentSummary')
    end
    alias :getcontentsummary :content_summary

    # curl -i "http://<HOST>:<PORT>/webhdfs/v1/<PATH>?op=GETFILECHECKSUM"
    def checksum(path, options={})
      check_options(options, OPT_TABLE['GETFILECHECKSUM'])
      res = operate_requests('GET', path, 'GETFILECHECKSUM', options)
      check_success_json(res, 'FileChecksum')
    end
    alias :getfilechecksum :checksum

    # curl -i "http://<HOST>:<PORT>/webhdfs/v1/?op=GETHOMEDIRECTORY"
    def homedir(options={})
      check_options(options, OPT_TABLE['GETHOMEDIRECTORY'])
      res = operate_requests('GET', '/', 'GETHOMEDIRECTORY', options)
      check_success_json(res, 'Path')
    end
    alias :gethomedirectory :homedir

    # curl -i -X PUT "http://<HOST>:<PORT>/webhdfs/v1/<PATH>?op=SETPERMISSION
    #                 [&permission=<OCTAL>]"
    def chmod(path, mode, options={})
      check_options(options, OPT_TABLE['SETPERMISSION'])
      res = operate_requests('PUT', path, 'SETPERMISSION', options.merge({'permission' => mode}))
      res.code == '200'
    end
    alias :setpermission :chmod

    # curl -i -X PUT "http://<HOST>:<PORT>/webhdfs/v1/<PATH>?op=SETOWNER
    #                          [&owner=<USER>][&group=<GROUP>]"
    def chown(path, options={})
      check_options(options, OPT_TABLE['SETOWNER'])
      unless options.has_key?('owner') or options.has_key?('group') or
          options.has_key?(:owner) or options.has_key?(:group)
        raise ArgumentError, "'chown' needs at least one of owner or group"
      end
      res = operate_requests('PUT', path, 'SETOWNER', options)
      res.code == '200'
    end
    OPT_TABLE['SETOWNER'] = ['owner', 'group']
    alias :setowner :chown

    # curl -i -X PUT "http://<HOST>:<PORT>/webhdfs/v1/<PATH>?op=SETREPLICATION
    #                           [&replication=<SHORT>]"
    def replication(path, replnum, options={})
      check_options(options, OPT_TABLE['SETREPLICATION'])
      res = operate_requests('PUT', path, 'SETREPLICATION', options.merge({'replication' => replnum.to_s}))
      check_success_json(res, 'boolean')
    end
    alias :setreplication :replication

    # curl -i -X PUT "http://<HOST>:<PORT>/webhdfs/v1/<PATH>?op=SETTIMES
    #                           [&modificationtime=<TIME>][&accesstime=<TIME>]"
    # motidicationtime: radix-10 logn integer
    # accesstime: radix-10 logn integer
    def touch(path, options={})
      check_options(options, OPT_TABLE['SETTIMES'])
      unless options.has_key?('modificationtime') or options.has_key?('accesstime') or
          options.has_key?(:modificationtime) or options.has_key?(:accesstime)
        raise ArgumentError, "'touch' needs at least one of modificationtime or accesstime"
      end
      res = operate_requests('PUT', path, 'SETTIMES', options)
      res.code == '200'
    end
    OPT_TABLE['SETTIMES'] = ['modificationtime', 'accesstime']
    alias :settimes :touch

    # def delegation_token(user, options={}) # GETDELEGATIONTOKEN
    #   raise NotImplementedError
    # end
    # def renew_delegation_token(token, options={}) # RENEWDELEGATIONTOKEN
    #   raise NotImplementedError
    # end
    # def cancel_delegation_token(token, options={}) # CANCELDELEGATIONTOKEN
    #   raise NotImplementedError
    # end

    def check_options(options, optdecl=[])
      ex = options.keys.map(&:to_s) - (optdecl || [])
      raise ArgumentError, "no such option: #{ex.join(' ')}" unless ex.empty?
    end

    def check_success_json(res, attr=nil)
      res.code == '200' and res.content_type == 'application/json' and (attr.nil? or JSON.parse(res.body)[attr])
    end

    def api_path(path)
      if path.start_with?('/')
        '/webhdfs/v1' + path
      else
        '/webhdfs/v1/' + path
      end
    end

    def build_path(path, op, params)
      opts = if @username and @doas
               {'op' => op, 'user.name' => @username, 'doas' => @doas}
             elsif @username
               {'op' => op, 'user.name' => @username}
             elsif @doas
               {'op' => op, 'doas' => @doas}
             else
               {'op' => op}
             end
      query = URI.encode_www_form(params.merge(opts))
      api_path(path) + '?' + query
    end

    def get_headers(add_octet_stream_header)
      headers = {}
      base64_token = ENV['WEBHDFS_DELEGATION_TOKEN_BASE64']
      if !base64_token.nil? then
        headers['X-Hadoop-Delegation-Token'] = base64_token
      end
      if add_octet_stream_header then
        headers['Content-Type'] = 'application/octet-stream'
      end
      if headers.length == 0 then
        return nil
      end
      return headers
    end

    REDIRECTED_OPERATIONS = ['APPEND', 'CREATE', 'OPEN', 'GETFILECHECKSUM']
    def operate_requests(method, path, op, params={}, payload=nil)
      headers = get_headers(
          (not @httpfs_mode and REDIRECTED_OPERATIONS.include?(op)) ||
          (@httpfs_mode and not payload.nil?))
      if not @httpfs_mode and REDIRECTED_OPERATIONS.include?(op)
        res = request(@host, @port, method, path, op, params, nil, headers)
        unless res.is_a?(Net::HTTPRedirection) and res['location']
          msg = "NameNode returns non-redirection (or without location header), code:#{res.code}, body:#{res.body}."
          raise WebHDFS::RequestFailedError, msg
        end
        uri = URI.parse(res['location'])
        rpath = if uri.query
                  uri.path + '?' + uri.query
                else
                  uri.path
                end
        request(uri.host, uri.port, method, rpath, nil, {}, payload, headers)
      else
        request(@host, @port, method, path, op, params, payload, headers)
      end
    end

    # IllegalArgumentException      400 Bad Request
    # UnsupportedOperationException 400 Bad Request
    # SecurityException             401 Unauthorized
    # IOException                   403 Forbidden
    # FileNotFoundException         404 Not Found
    # RumtimeException              500 Internal Server Error
    def request(host, port, method, path, op=nil, params={}, payload=nil, header=nil, retries=0)
      conn = connection(host, port) # private function that implements reuse

      path = Addressable::URI.escape(path) # make path safe for transmission via HTTP
      request_path = if op
                       build_path(path, op, params)
                     else
                       path
                     end

      gsscli = nil
      if @kerberos
        require 'base64'
        require 'gssapi'
        gsscli = GSSAPI::Simple.new(@host, 'HTTP', @kerberos_keytab)
        token = nil
        begin
          token = gsscli.init_context
        rescue => e
          raise WebHDFS::KerberosError, e.message
        end
        if header
          header['Authorization'] = "Negotiate #{Base64.strict_encode64(token)}"
        else
          header = {'Authorization' => "Negotiate #{Base64.strict_encode64(token)}"}
        end
      end

      res = nil
      if !payload.nil? and payload.respond_to? :read and payload.respond_to? :size
        req = Net::HTTPGenericRequest.new(method,(payload ? true : false),true,request_path,header)
        raise WebHDFS::ClientError, 'Error accepting given IO resource as data payload, Not valid in methods other than PUT and POST' unless (method == 'PUT' or method == 'POST')

        req.body_stream = payload
        req.content_length = payload.size
        res = conn.request(req)
      else
        res = conn.send_request(method, request_path, payload, header)
      end

      if @kerberos and res.code == '307'
        itok = (res.header.get_fields('WWW-Authenticate') || ['']).pop.split(/\s+/).last
        unless itok
          raise WebHDFS::KerberosError, 'Server does not return WWW-Authenticate header'
        end

        begin
          gsscli.init_context(Base64.strict_decode64(itok))
        rescue => e
          raise WebHDFS::KerberosError, e.message
        end
      end

      case res
      when Net::HTTPSuccess
        res
      when Net::HTTPRedirection
        res
      else
        message = if res.body and not res.body.empty?
                    res.body.gsub(/\n/, '')
                  else
                    'Response body is empty...'
                  end

        if @retry_known_errors && retries < @retry_times
          detail = nil
          if message =~ /^\{"RemoteException":\{/
            begin
              detail = JSON.parse(message)
            rescue
              # ignore broken json response body
            end
          end
          if detail && detail['RemoteException'] && KNOWN_ERRORS.include?(detail['RemoteException']['exception'])
            sleep @retry_interval if @retry_interval > 0
            return request(host, port, method, path, op, params, payload, header, retries+1)
          end
        end

        case res.code
        when '400'
          raise WebHDFS::ClientError, message
        when '401'
          raise WebHDFS::SecurityError, message
        when '403'
          raise WebHDFS::IOError, message
        when '404'
          raise WebHDFS::FileNotFoundError, message
        when '500'
          raise WebHDFS::ServerError, message
        else
          raise WebHDFS::RequestFailedError, "response code:#{res.code}, message:#{message}"
        end
      end
    end

    private

    #
    # Get an existing or new HTTP connection.  Provides the ability
    # to reuse a HTTP connection for multiple calls to the same
    # host:port.  This reuse optimization can improve performance by
    # a factor of 2 for applications that perform a lot of metadata
    # operations.
    #
    def connection(host, port)
      # check whether an existing connection is ready to use
      conn = reuse_connection_if_possible(host, port)
      return conn if conn

      # create and set up a new connection
      conn = create_connection(host, port)

      # set up to reuse the connection, if this option is configured
      return conn unless @reuse_connection

      # conn.start is required to keep HTTP connection open between requests.
      # The corresponding conn.finish is performed (when necessary)
      # in reuse_connection_if_possible.  When start is not called,
      # Net::HTTP sets the HTTP request 'Connection' header to 'close',
      # causing the server to terminate the HTTP connection after every
      # request.  For more information, see the documentation for Net::HTTP.
      conn.start
      @connection = { 'host' => host, 'port' => port, 'conn' => conn }
      conn
    end

    #
    # Create a new Net::HTTP connection and set it up according
    # to the configuration of this object.
    #
    def create_connection(host, port)
      conn = Net::HTTP.new(host, port, @proxy_address, @proxy_port)
      conn.proxy_user = @proxy_user if @proxy_user
      conn.proxy_pass = @proxy_pass if @proxy_pass
      conn.open_timeout = @open_timeout if @open_timeout
      conn.read_timeout = @read_timeout if @read_timeout

      # configure ssl, if required
      return conn unless @ssl
      conn.use_ssl = true
      conn.ca_file = @ssl_ca_file if @ssl_ca_file

      # configure ssl_verify_mode if required
      return conn unless @ssl_verify_mode
      require 'openssl'
      conn.verify_mode = case @ssl_verify_mode
                         when :none then OpenSSL::SSL::VERIFY_NONE
                         when :peer then OpenSSL::SSL::VERIFY_PEER
                         end
      conn
    end

    #
    # Check whether it is possible to reuse an existing connection.
    # This check will only succeed if:
    # - The class variable @reuse_connection is set.
    # - The connection has already been established to the requested
    #   host and port.
    #
    # If the connection exists, but does not correspond to the requested
    # host and port, then the existing connection is terminated.
    #
    def reuse_connection_if_possible(host, port)
      return nil unless @connection
      if (@connection['host'] = host) && (@connection['port'] = port)
        return @connection['conn']
      end
      @connection['conn'].finish # matches conn.start in connection()
      @connection = nil # set to nil and return
    end
  end
end
