require File.expand_path('../../../load_paths', __FILE__)

$:.unshift(File.dirname(__FILE__) + '/lib')
$:.unshift(File.dirname(__FILE__) + '/fixtures/helpers')
$:.unshift(File.dirname(__FILE__) + '/fixtures/alternate_helpers')

ENV['TMPDIR'] = File.join(File.dirname(__FILE__), 'tmp')

require 'test/unit'
require 'abstract_controller'
require 'action_controller'
require 'action_view'
require 'action_view/base'
require 'action_dispatch'
require 'fixture_template'
require 'active_support/dependencies'
require 'active_model'

begin
  require 'ruby-debug'
  Debugger.settings[:autoeval] = true
  Debugger.start
rescue LoadError
  # Debugging disabled. `gem install ruby-debug` to enable.
end

require 'pp' # require 'pp' early to prevent hidden_methods from not picking up the pretty-print methods until too late

ActiveSupport::Dependencies.hook!

# Show backtraces for deprecated behavior for quicker cleanup.
ActiveSupport::Deprecation.debug = true

# Register danish language for testing
I18n.backend.store_translations 'da', {}
I18n.backend.store_translations 'pt-BR', {}
ORIGINAL_LOCALES = I18n.available_locales.map {|locale| locale.to_s }.sort

FIXTURE_LOAD_PATH = File.join(File.dirname(__FILE__), 'fixtures')
FIXTURES = Pathname.new(FIXTURE_LOAD_PATH)

module SetupOnce
  extend ActiveSupport::Concern

  included do
    cattr_accessor :setup_once_block
    self.setup_once_block = nil

    setup :run_setup_once
  end

  module ClassMethods
    def setup_once(&block)
      self.setup_once_block = block
    end
  end

  private
    def run_setup_once
      if self.setup_once_block
        self.setup_once_block.call
        self.setup_once_block = nil
      end
    end
end

SharedTestRoutes = ActionDispatch::Routing::RouteSet.new

module ActiveSupport
  class TestCase
    include SetupOnce
    # Hold off drawing routes until all the possible controller classes
    # have been loaded.
    setup_once do
      SharedTestRoutes.draw do |map|
        match ':controller(/:action(/:id))'
      end

      ActionController::IntegrationTest.app.router.draw do
        match ':controller(/:action(/:id))'
      end
    end
  end
end

class RoutedRackApp
  attr_reader :router

  def initialize(router, &blk)
    @router = router
    @stack = ActionDispatch::MiddlewareStack.new(&blk).build(@router)
  end

  def call(env)
    @stack.call(env)
  end
end

class ActionController::IntegrationTest < ActiveSupport::TestCase
  def self.build_app(routes = nil)
    RoutedRackApp.new(routes || ActionDispatch::Routing::RouteSet.new) do |middleware|
      middleware.use "ActionDispatch::ShowExceptions"
      middleware.use "ActionDispatch::Callbacks"
      middleware.use "ActionDispatch::ParamsParser"
      middleware.use "ActionDispatch::Cookies"
      middleware.use "ActionDispatch::Flash"
      middleware.use "ActionDispatch::Head"
    end
  end

  self.app = build_app

  class StubDispatcher
    def self.new(*args)
      lambda { |env|
        params = env['action_dispatch.request.path_parameters']
        controller, action = params[:controller], params[:action]
        [200, {'Content-Type' => 'text/html'}, ["#{controller}##{action}"]]
      }
    end
  end

  def self.stub_controllers
    old_dispatcher = ActionDispatch::Routing::RouteSet::Dispatcher
    ActionDispatch::Routing::RouteSet.module_eval { remove_const :Dispatcher }
    ActionDispatch::Routing::RouteSet.module_eval { const_set :Dispatcher, StubDispatcher }
    yield ActionDispatch::Routing::RouteSet.new
  ensure
    ActionDispatch::Routing::RouteSet.module_eval { remove_const :Dispatcher }
    ActionDispatch::Routing::RouteSet.module_eval { const_set :Dispatcher, old_dispatcher }
  end

  def with_routing(&block)
    temporary_routes = ActionDispatch::Routing::RouteSet.new
    old_app, self.class.app = self.class.app, self.class.build_app(temporary_routes)
    old_routes = SharedTestRoutes
    silence_warnings { Object.const_set(:SharedTestRoutes, temporary_routes) }

    yield temporary_routes
  ensure
    self.class.app = old_app
    silence_warnings { Object.const_set(:SharedTestRoutes, old_routes) }
  end
end

# Temporary base class
class Rack::TestCase < ActionController::IntegrationTest
  setup do
    ActionController::Base.session_options[:key] = "abc"
    ActionController::Base.session_options[:secret] = ("*" * 30)
  end

  def self.testing(klass = nil)
    if klass
      @testing = "/#{klass.name.underscore}".sub!(/_controller$/, '')
    else
      @testing
    end
  end

  def get(thing, *args)
    if thing.is_a?(Symbol)
      super("#{self.class.testing}/#{thing}", *args)
    else
      super
    end
  end

  def assert_body(body)
    assert_equal body, Array.wrap(response.body).join
  end

  def assert_status(code)
    assert_equal code, response.status
  end

  def assert_response(body, status = 200, headers = {})
    assert_body   body
    assert_status status
    headers.each do |header, value|
      assert_header header, value
    end
  end

  def assert_content_type(type)
    assert_equal type, response.headers["Content-Type"]
  end

  def assert_header(name, value)
    assert_equal value, response.headers[name]
  end
end

class ::ApplicationController < ActionController::Base
end

module ActionController
  class Base
    include ActionController::Testing
  end

  Base.view_paths = FIXTURE_LOAD_PATH

  class TestCase
    include ActionDispatch::TestProcess

    setup do
      # ROUTES TODO: The router object should come from somewhere sane
      @router = SharedTestRoutes
    end

    def assert_template(options = {}, message = nil)
      validate_request!

      hax = @controller.view_context.instance_variable_get(:@_rendered)

      case options
      when NilClass, String
        rendered = (hax[:template] || []).map { |t| t.identifier }
        msg = build_message(message,
                "expecting <?> but rendering with <?>",
                options, rendered.join(', '))
        assert_block(msg) do
          if options.nil?
            hax[:template].blank?
          else
            rendered.any? { |t| t.match(options) }
          end
        end
      when Hash
        if expected_partial = options[:partial]
          partials = hax[:partials]
          if expected_count = options[:count]
            found = partials.detect { |p, _| p.identifier.match(expected_partial) }
            actual_count = found.nil? ? 0 : found[1]
            msg = build_message(message,
                    "expecting ? to be rendered ? time(s) but rendered ? time(s)",
                     expected_partial, expected_count, actual_count)
            assert(actual_count == expected_count.to_i, msg)
          else
            msg = build_message(message,
                    "expecting partial <?> but action rendered <?>",
                    options[:partial], partials.keys)
            assert(partials.keys.any? { |p| p.identifier.match(expected_partial) }, msg)
          end
        else
          assert hax[:partials].empty?,
            "Expected no partials to be rendered"
        end
      end
    end
  end
end

# This stub emulates the Railtie including the URL helpers from a Rails application
module ActionController
  class Base
    include SharedTestRoutes.url_helpers
  end
end