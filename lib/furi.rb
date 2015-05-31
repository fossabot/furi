require "cgi"
require "furi/version"

module Furi

  PARTS =  [
    :anchor, :protocol, :query_string, 
    :path, :host, :port, :username, :password
  ]
  ALIASES = {
    protocol: [:schema],
    anchor: [:fragment],
  }

  DELEGATES = [:port!]
  
  PORT_MAPPING = {
    "http" => 80,
    "https" => 443,
    "ftp" => 21,
    "tftp" => 69,
    "sftp" => 22,
    "ssh" => 22,
    "svn+ssh" => 22,
    "telnet" => 23,
    "nntp" => 119,
    "gopher" => 70,
    "wais" => 210,
    "ldap" => 389,
    "prospero" => 1525
  }

  class Expressions
    attr_accessor :protocol

    def initialize
      @protocol = /^[a-z][a-z0-9.+-]*$/i
    end
  end

  def self.expressions
    Expressions.new
  end

  def self.parse(string)
    URI.new(string)
  end

  class << self
    (PARTS + ALIASES.values.flatten + DELEGATES).each do |part|
      define_method(part) do |string|
        URI.new(string).send(part)
      end
    end
  end

  def self.update(string, parts)
    parse(string).update(parts).to_s
  end

  def self.serialize(query, namespace = nil)
    case query
    when Hash
      query.map do |key, value|
        unless (value.is_a?(Hash) || value.is_a?(Array)) && value.empty?
          serialize(value, namespace ? "#{namespace}[#{key}]" : key)
        else
          nil
        end
      end.flatten.compact.sort!.join('&')
    when Array
      namespace = "#{namespace}[]"
      query.map do |item|
        serialize(item, namespace)
      end
    else
      "#{CGI.escape(namespace.to_s)}=#{CGI.escape(query.to_s)}"
    end
  end

  class URI

    attr_reader(*PARTS)

    ALIASES.each do |origin, aliases|
      aliases.each do |aliaz|
        define_method(aliaz) do
          send(origin)
        end
      end
    end

    def initialize(string)
      string, *@anchor = string.split("#")
      @anchor = @anchor.empty? ? nil : @anchor.join("#")
      if string.include?("?")
        string, query_string = string.split("?", 2)
        @query_string = query_string
      end

      if string.include?("://")
        @protocol, string = string.split(":", 2)
        @protocol = nil if @protocol.empty?
      end
      if string.start_with?("//")
        string = string[2..-1]
      end
      parse_authority(string)
    end

    def update(parts)
      parts.each do |part, value|
        send(:"#{part}=", value)
      end
      self
    end

    def to_s
      result = []
      if protocol
        result << "#{protocol}://"
      end
      result << host
      result << path
      if query_string
        result << "?"
        result << query_string
      end
      if anchor
        result << "#"
        result << anchor
      end
      result.join
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
      if string.include?(":")
        string, @port = string.split(":", 2)
        @port = @port.to_i
      end
      if string.empty?
        @host = nil
      else
        @host = string
      end
    end

    def query
      return @query if query_level?
      @query = parse_query_string(@query_string)
    end

    def parse_query_string(string)
      params = {}
      return params if !string || string.empty?
      string.split(/[&;]/).each do |pairs|
        key, value = pairs.split('=',2).select{|v| CGI::unescape(v) }
        params[key] = value
      end
      params
    end

    def query=(value)
      @query = case value
               when String then raise parse_query_string(value)
               when Hash then value
               else 
                 raise 'Query can only be Hash or String'
               end
    end

    def query_string
      return @query_string unless query_level?
      Furi.serialize(@query)
    end

    def expressions
      Furi.expressions
    end

    def port!
      return port if port
      return PORT_MAPPING[protocol] if protocol
      nil
    end

    protected

    def query_level?
      !!defined?(@query)
    end
  end
end
