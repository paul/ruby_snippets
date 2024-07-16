# frozen_string_literal: true

# Author:  Paul Sadauskas<paul@sadauskas.com>
# License: MIT

require "http"
require "mustermann"

# Acts like the HTTP gem, but doesn't make any real requests. Instead, you can
# manually stub them out:
#
# let(:http) do
#   FakeHTTP.new do
#     get "/foo" do
#       status 200
#       { foo: bar }
#     end
#   end
# end
# let(:client) { MyClient.new(http: http) }
#
class FakeHTTP
  include HTTP::Chainable

  attr_reader :builder

  def initialize(context = {}, &block)
    @builder = Builder.new(context)
    @builder.instance_eval(&block)
  end

  def merge(other = nil, &block)
    @builder.merge(other.builder) if other
    @builder.instance_eval(&block) if block
    self
  end
  alias_method :merge!, :merge

  def requests
    @builder.requests
  end

  def self.follow
    self
  end

  private

  def branch(options)
    Client.new(options, builder: @builder)
  end

  class Client
    include HTTP::Chainable

    def initialize(options, builder:)
      @options, @builder = options, builder
    end

    def request(verb, uri, options = {})
      @builder.request(verb, uri, @options.merge(options))
    end

    def branch(options)
      self.class.new(@options.merge(options), builder: @builder)
    end

    def close; end
  end

  class Builder
    attr_reader :fakes

    def initialize(context = {})
      @context = context
      @fakes = Hash.new { |h, k| h[k] = [] }
    end

    def get(pattern, &block)
      add_responder(:get, pattern, &block)
    end

    def post(pattern, &block)
      add_responder(:post, pattern, &block)
    end

    def put(pattern, &block)
      add_responder(:put, pattern, &block)
    end

    def patch(pattern, &block)
      add_responder(:patch, pattern, &block)
    end

    def delete(pattern, &block)
      add_responder(:delete, pattern, &block)
    end

    def merge(other)
      other.fakes.each do |verb, responders|
        @fakes[verb].unshift(*responders)
      end
    end

    def request(verb, uri, options = {})
      path = URI.parse(uri.to_s).path
      responders = @fakes[verb].select { |matcher| matcher.score(path) }
      responder = responders.min_by { |matcher| matcher.score(path) }
      unless responder
        raise <<~STR
          No path detected or match for #{verb} #{uri} in the list of defined paths

          responders - #{@fakes}
        STR
      end

      requests[path][verb] << options
      Rails.logger.debug { "==> #{verb.upcase} #{path}" }
      responder.call(uri, options, @context[:content_type]).tap do |resp|
        Rails.logger.debug { "<== #{resp.status}" }
      end
    end

    # { :get => { "/foo/bar" => [ { request 1 options }, { request 2 options }, ... ] } }
    def requests
      @requests ||= Hash.new { |h, k| h[k] = Hash.new { |h, k| h[k] = [] } }
    end

    private

    def add_responder(verb, pattern, &block)
      responder = Responder.new(pattern, @context, block)
      @fakes[verb].unshift(responder)
    end
  end

  class Responder
    def initialize(pattern, context, code)
      @pattern = Mustermann.new(pattern)
      @context, @code = context, code
    end

    attr_reader :context

    def match(uri)
      @pattern.match(uri)
    end

    def score(uri)
      return nil unless match(uri)

      @pattern.params(uri).size
    end

    def call(uri, options, content_type)
      params = @pattern.params(uri.to_s)
      status(200)
      content_type(content_type)
      result = instance_exec(params, options, &@code)
      body = result.is_a?(Hash) ? result.to_json : result.to_s

      HTTP::Response.new(status: status, version: "1.1", headers: headers, body: body, uri: uri)
    end

    def status(new_status = nil)
      @status = new_status if new_status
      @status
    end

    def content_type(mime_type)
      headers["Content-Type"] = mime_type || "application/json"
    end

    def headers
      @headers ||= {}
    end
  end
end
