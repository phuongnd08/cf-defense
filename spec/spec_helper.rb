require 'minitest/autorun'
require 'rack/test'
require 'redis'
require 'redis_test'
require 'timecop'
require 'cf-defense'

class MiniTest::Spec
  include Rack::Test::Methods

  def status_ok; 200 end
  def status_throttled; 429 end
  def status_banned; 403 end

  def app
    Rack::Builder.new {
      use CfDefense::Middleware
      run ->(_) { [200, {}, ['Hello World']] }
    }.to_app
  end

  STDOUT.puts "MiniTest::global-initialize"
  Timecop.safe_mode = true
  RedisTest.start
  RedisTest.configure(:default)

  before do
    RedisTest.clear
  end
end
