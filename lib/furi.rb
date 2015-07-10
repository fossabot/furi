require "furi/version"
require "uri"

module Furi

  PARTS =  [
    :anchor, :protocol, :query_tokens,
    :path, :host, :port, :username, :password
  ]
  ALIASES = {
    protocol: [:schema, :scheme],
    anchor: [:fragment],
    host: [:hostname]
  }

  DELEGATES = [:port!]

  PROTOCOLS = {
    "http" => {port: 80},
    "https" => {port: 443, secure: true},
    "ftp" => {port: 21},
    "tftp" => {port: 69},
    "sftp" => {port: 22},
    "ssh" => {port: 22, secure: true},
    "svn+ssh" => {port: 22, secure: true},
    "telnet" => {port: 23},
    "nntp" => {port: 119},
    "gopher" => {port: 70},
    "wais" => {port: 210},
    "ldap" => {port: 389},
    "prospero" => {port: 1525},
  }

  ROOT = '/'

  class Expressions
    attr_accessor :protocol

    def initialize
      @protocol = /^[a-z][a-z0-9.+-]*$/i
    end
  end

  def self.expressions
    Expressions.new
  end

  def self.parse(argument)
    Uri.new(argument)
  end

  def self.build(argument)
    Uri.new(argument).to_s
  end

  class << self
    (PARTS + ALIASES.values.flatten + DELEGATES).each do |part|
      define_method(part) do |string|
        Uri.new(string).send(part)
      end
    end
  end

  def self.update(string, parts)
    parse(string).update(parts).to_s
  end

  def self.serialize_tokens(query, namespace = nil)
    case query
    when Hash
      result = query.map do |key, value|
        unless (value.is_a?(Hash) || value.is_a?(Array)) && value.empty?
          serialize_tokens(value, namespace ? "#{namespace}[#{key}]" : key)
        else
          nil
        end
      end
      result.flatten!
      result.compact!
      result
    when Array
      if namespace.nil? || namespace.empty?
        raise ArgumentError, "Can not serialize Array without namespace"
      end

      namespace = "#{namespace}[]"
      query.map do |item|
        if item.is_a?(Array)
          raise ArgumentError, "Can not serialize #{item.inspect} as element of an Array"
        end
        serialize_tokens(item, namespace)
      end
    else
      if namespace
        QueryToken.new(namespace, query)
      else
        []
      end
    end
  end

  def self.parse_nested_query(qs)

    params = {}
    query_tokens(qs).each do |token|
      parse_query_token(params, token.name, token.value)
    end

    return params
  end

  def self.query_tokens(query)
    if query.is_a?(Array)
      query.map do |token|
        case token
        when QueryToken
          token
        when String
          QueryToken.parse(token)
        when Array
          QueryToken.new(*token)
        else
          raise ArgumentError, "Can not parse query token #{token.inspect}"
        end
      end
    else
      (query || '').split(/[&;] */n).map do |p|
        QueryToken.parse(p)
      end
    end
  end

  def self.parse_query_token(params, name, value)
    name =~ %r(\A[\[\]]*([^\[\]]+)\]*)
    namespace = $1 || ''
    after = $' || ''

    return if namespace.empty?

    current = params[namespace]
    if after == ""
      current = value
    elsif after == "[]"
      current ||= []
      unless current.is_a?(Array)
        raise TypeError, "expected Array (got #{current.class}) for param `#{namespace}'"
      end
      current << value
    elsif after =~ %r(^\[\]\[([^\[\]]+)\]$) || after =~ %r(^\[\](.+)$)
      child_key = $1
      current ||= []
      unless current.is_a?(Array)
        raise TypeError, "expected Array (got #{current.class}) for param `#{namespace}'"
      end
      if current.last.is_a?(Hash) && !current.last.key?(child_key)
        parse_query_token(current.last, child_key, value)
      else
        current << parse_query_token({}, child_key, value)
      end
    else
      current ||= {}
      unless current.is_a?(Hash)
        raise TypeError, "expected Hash (got #{current.class}) for param `#{namespace}'"
      end
      current = parse_query_token(current, after, value)
    end
    params[namespace] = current

    return params
  end

  def self.serialize(query, namespace = nil)
    serialize_tokens(query, namespace).join("&")
  end

  class QueryToken
    attr_reader :name, :value

    def self.parse(token)
      k,v = token.split('=', 2).map { |s| ::URI.decode_www_form_component(s) }
      new(k,v)
    end

    def initialize(name, value)
      @name = name
      @value = value
    end

    def to_a
      [name, value]
    end

    def to_s
      "#{::URI.encode_www_form_component(name.to_s)}=#{::URI.encode_www_form_component(value.to_s)}"
    end

    def inspect
      [name, value].join('=')
    end
  end

  class Uri

    attr_reader(*PARTS)

    ALIASES.each do |origin, aliases|
      aliases.each do |aliaz|
        define_method(aliaz) do
          send(origin)
        end

        define_method(:"#{aliaz}=") do |*args|
          send(:"#{origin}=", *args)
        end
      end
    end

    def initialize(argument)
      @query_tokens = []
      case argument
      when String
        parse_uri_string(argument)
      when Hash
        update(argument)
      end
    end

    def update(parts)
      parts.each do |part, value|
        send(:"#{part}=", value)
      end
      self
    end

    def merge(parts)
      parts.each do |part, value|
        case part.to_sym
        when :query
          merge_query(value)
        else
          send(:"#{part}=", value)
        end
      end
    end

    def merge_query(query)
      case query
      when Hash
        self.query.merge!(parse_nested_query(query))
      when String, Array
        self.query_tokens += Furi.query_tokens(query)
      else
        raise ArgumentError
      end
    end

    def userinfo
      if username
        [username, password].compact.join(":")
      elsif password
        raise FormattingError, "can not build URI with password but without username"
      else
        nil
      end
    end
    
    def host=(host)
      @host = host
    end

    def to_s
      result = []
      if protocol
        result.push(protocol.empty? ? "//" : "#{protocol}://")
      end
      if userinfo
        result << userinfo
      end
      result << host if host
      result << ":" << port if explicit_port
      result << (host ? path : path!)
      if query_tokens.any?
        result << "?" << query_tokens.join("&")
      end
      if anchor
        result << "#" << anchor
      end
      result.join
    end

    
    def resource
      [request, anchor].compact.join("#")
    end

    def path!
      path || ROOT
    end

    def host!
      host || ""
    end
    
    def request
      result = []
      result << path!
      result << "?" << query_tokens if query_tokens.any?
      result.join
    end

    def request_uri
      request
    end

    def query
      return @query if query_level?
      @query = Furi.parse_nested_query(query_tokens)
    end


    def query=(value)
      @query = nil
      @query_tokens = []
      case value
      when String, Array
        @query_tokens = Furi.query_tokens(value)
      when Hash
        @query = value
        @query_tokens = Furi.serialize_tokens(value)
      when nil
      else
        raise ArgumentError, 'Query can only be Hash or String'
      end
    end

    def port=(port)
      if port != nil
        @port = port.to_i
        if @port == 0
          raise ArgumentError, "port should be an Integer > 0"
        end
      else
        @port = nil
      end
      @port
    end

    def query_tokens=(tokens)
      @query = nil
      @query_tokens = tokens
    end

    def username=(username)
      @username = username.nil? ? nil : username.to_s
    end

    def password=(password)
      @password = password.nil? ? nil : password.to_s
    end

    def path=(path)
      @path = path.to_s
    end

    def protocol=(protocol)
      @protocol = protocol ? protocol.gsub(%r{:/?/?\Z}, "") : nil
    end

    def query_string
      if query_level?
        Furi.serialize(@query)
      else
        query_tokens.join("&")
      end
    end

    def expressions
      Furi.expressions
    end

    def port!
      port || default_port
    end

    def default_port
      protocol && PROTOCOLS[protocol] ? PROTOCOLS[protocol][:port] : nil
    end

    def ssl?
      secure?
    end

    def secure?
      !!(protocol && PROTOCOLS[protocol][:secure])
    end

    def filename
      path.split("/").last
    end

    def default_web_port?
      [PROTOCOLS['http'][:port], PROTOCOLS['https'][:port]].include?(port!) 
    end
    
    protected

    def query_level?
      !!@query
    end

    def explicit_port
      port == default_port ? nil : port
    end

    def parse_uri_string(string)
      string, *@anchor = string.split("#")
      @anchor = @anchor.empty? ? nil : @anchor.join("#")
      if string.include?("?")
        string, query_string = string.split("?", 2)
        self.query_tokens = Furi.query_tokens(query_string)
      end

      if string.include?("://")
        @protocol, string = string.split(":", 2)
        @protocol = '' if @protocol.empty?
      end
      if string.start_with?("//")
        @protocol ||= ''
        string = string[2..-1]
      end
      parse_authority(string)
    end

    def parse_authority(string)
      if string.include?("/")
        string, @path = string.split("/", 2)
        @path = "/" + @path
      end

      if string.include?("@")
        userinfo, string = string.split("@", 2)
        @username, @password = userinfo.split(":", 2)
      end
      host, port = string.split(":", 2)
      self.host = host if host
      self.port = port if port
    end

  end

  class FormattingError < StandardError
  end
end
