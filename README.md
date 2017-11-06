Rack::Defense
=============

A Rack middleware for throttling and filtering requests.

[![Build Status](https://travis-ci.org/nakhli/rack-defense.svg)](https://travis-ci.org/nakhli/rack-defense)
[![Security](https://hakiri.io/github/nakhli/rack-defense/master.svg)](https://hakiri.io/github/nakhli/rack-defense/master)
[![Code Climate](https://codeclimate.com/github/nakhli/rack-defense/badges/gpa.svg)](https://codeclimate.com/github/nakhli/rack-defense)
[![Dependency Status](https://gemnasium.com/nakhli/rack-defense.svg)](https://gemnasium.com/nakhli/rack-defense)
[![Gem Version](https://badge.fury.io/rb/rack-defense.svg)](http://badge.fury.io/rb/rack-defense)

Rack::Defense is a Rack middleware that allows to easily add request rate limiting and request filtering to your Rack based application (Ruby On Rails, Sinatra etc.).

* [Request throttling](#throttling) (aka rate limiting) happens on __sliding window__ using the provided period, request criteria and maximum request number. It uses Redis to track the request rate.

* [Request filtering](#filtering) bans (rejects) requests based on provided criteria.

Rack::Defense has a small footprint and only two dependencies: [rack](https://github.com/rack/rack) and [redis](https://github.com/redis/redis-rb).

Rack::Defense is inspired from the [Rack::Attack](https://github.com/kickstarter/rack-attack) project. The main difference is the throttling algorithm: Rack::Attack uses a counter reset at the end of each period, therefore allowing up to 2 times more requests than the maximum rate specified. We use a sliding window algorithm allowing a precise request rate limiting.

## Getting started

Install the rack-defense gem; or add it to you Gemfile with bundler:

```ruby
# In your Gemfile
gem 'rack-defense'
```

Tell your app to use the Rack::Defense middleware. For Rails 3+ apps:

```ruby
# In config/application.rb
config.middleware.use Rack::Defense
```

Or for Rackup files:

```ruby
# In config.ru
use Rack::Defense
```

Add a `rack-defense.rb` file to `config/initializers/`:

```ruby
# In config/initializers/rack-defense.rb
Rack::Defense.setup do |config|
  # your configuration here
end
```

## Throttling

The Rack::Defense middleware evaluates the throttling criteria (lambdas) against the incoming request.
If the return value is falsy, the request is not throttled. Otherwise, the returned value is used as a key to
throttle the request. The returned key could be the request IP, user name, API token or any discriminator to throttle
the requests against.

### Examples

Throttle POST requests for path `/login` with a maximum rate of 3 request per minute per IP:

```ruby
Rack::Defense.setup do |config|
  config.throttle('login', 3, 60 * 1000) do |req|
    req.ip if req.path == '/login' && req.post?
  end
end
```

Throttle GET requests for path `/api/*` with a maximum rate of 50 request per second per API token:

```ruby
Rack::Defense.setup do |config|
  config.throttle('api', 50, 1000) do |req|
    req.env['HTTP_AUTHORIZATION'] if %r{^/api/} =~ req.path
  end 
end
```

Throttle POST requests for path `/aggregate/report` with a maximum rate of 10 requests per hour for a given logged in user. We assume here that we are using the [Warden](https://github.com/hassox/warden) middleware for authentication or any Warden based authentication wrapper, like [Devise](https://github.com/plataformatec/devise) in Rails.

```ruby
Rack::Defense.setup do |config|
  config.throttle('aggregate_report', 10, 1.hour.in_milliseconds) do |req|
    req.env['warden'].user.id if req.path == '/aggregate/report' && req.env['warden'].user
  end 
end
```

### Redis Configuration

Rack::Defense uses Redis to track request rates. By default, the `REDIS_URL` environment variable is used to setup
the store. If not set, it falls back to host `127.0.0.1` port `6379`.
The redis store can be setup with either a connection url: 

```ruby
Rack::Defense.setup do |config|
  config.store = "redis://:p4ssw0rd@10.0.1.1:6380/15"
end
```

or directly with a connection object:

```ruby
Rack::Defense.setup do |config|
  config.store = Redis.new(host: "10.0.1.1", port: 6380, db: 15)
end
```

## Filtering

Rack::Defense can reject requests based on arbitrary properties of the request. Matching requests are filtered out.

### Examples

Allow only a whitelist of IPs for a given path:

```ruby
Rack::Defense.setup do |config|
  config.ban('ip_whitelist') do |req|
    req.path == '/protected' && !['192.168.0.1', '127.0.0.1'].include?(req.ip)
  end
end
```

Deny access to a blacklist of application users. Again, we assume here that 
[Warden](https://github.com/hassox/warden) or any Warden based authentication wrapper, like [Devise](https://github.com/plataformatec/devise), is used:

```ruby
Rack::Defense.setup do |config|
  config.ban('user_blacklist') do |req|
    ['hacker@example.com', 'badguy@example.com'].include? req.env['warden'].user.email
  end 
end
```

Allow only requests with a known API authorization token:

```ruby
Rack::Defense.setup do |config|
  config.ban('validate_api_token') do |req|
    %r{^/api/} =~ req.path && Redis.current.sismember('apitokens', req.env['HTTP_AUTHORIZATION'])
  end
end
```

The previous example uses redis to keep track of valid api tokens, but any store (database, key-value store etc.) would do here.

## Response configuration

By default, Rack::Defense returns `429 Too Many Requests` and `403 Forbidden` respectively for throttled and banned requests.
These responses can be fully configured in the setup:

```ruby
Rack::Defense.setup do |config|
  config.banned_response =
    ->(env) { [404, {'Content-Type' => 'text/plain'}, ["Not Found\n"]] }
  config.throttled_response =
    ->(env) { [503, {'Content-Type' => 'text/plain'}, ["Service Unavailable\n"]] }
end
```

## Notifications

You can be notified when requests are throttled or banned. The callback receives the throttled request object and data
about the event context.

For banned request callbacks, the triggered rule name is passed: 

```ruby
Rack::Defense.setup do |config|
  config.after_ban do |req, rule|
    logger.info "[Banned] #{rule} #{req.path} #{req.ip}"
  end
end
```

For throttled request callbacks, a hash having triggered rule names as keys and the corresponding throttle keys
as values is passed. 

```ruby
Rack::Defense.setup do |config|
  config.after_throttle do |req, rules|
    logger.info rules.map { |e| "[Throttled] rule name: #{e[0]} - rule throttle key: #{e[1]}" }.join ', '
  end
end
```

## Advanced Examples

### Temporarily suspend access to suspicious IPs

In this example, when an IP is exceeding the permitted request rate, we would like to ban this IP for a given period of time:

```ruby
Rack::Defense.setup do |config|
  config.throttle('reset_password', 10, 10.minutes.in_milliseconds) do |req|
    req.ip if req.path == '/api/users/password' && req.post?
  end

  config.after_throttle do |req, rules|
    config.store.setex("ban:ip:#{req.ip}", 1.hour, 1) if rules.key? 'reset_password'
  end

  config.ban('blacklist') do |req|
    config.store.exists("ban:ip:#{req.ip}")
  end
end
```

The first rule named `reset_password` defines the maximum permitted rate per IP for post requests on path
`/api/users/password`. Once a user exceeds this limit, it gets throttled and denied access to the resource.
This raises a throttle event and triggers the `after_throttle` callback defined above. The callback sets a key in the redis store post-fixed with the user IP and having 1 hour an expiration time.

The last rule named `blacklist` looks up each incoming request IP and checks if it has a corresponding ban key
in redis. If the request IP matches a ban key it gets denied.

## License

Licensed under the [MIT License](http://opensource.org/licenses/MIT).

Copyright Chaker Nakhli.

