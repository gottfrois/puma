# frozen_string_literal: true

require_relative "helper"
require_relative "helpers/ssl" if ::Puma::HAS_SSL
require_relative "helpers/tmp_path"

require "puma/binder"
require "puma/events"
require "puma/configuration"

class TestBinderBase < Minitest::Test
  include SSLHelper if ::Puma::HAS_SSL
  include TmpPath

  def setup
    @events = Puma::Events.strings
    @binder = Puma::Binder.new(@events)
  end

  def teardown
    @binder.ios.reject! { |io| Minitest::Mock === io || io.to_io.closed? }
    @binder.close
    @binder.unix_paths.select! { |path| File.exist? path }
    @binder.close_listeners
  end

  private

  def ssl_context_for_binder(binder = @binder)
    binder.ios[0].instance_variable_get(:@ctx)
  end
end

class TestBinder < TestBinderBase
  parallelize_me!

  def test_synthesize_binds_from_activated_fds_no_sockets
    binds = ['tcp://0.0.0.0:3000']
    result = @binder.synthesize_binds_from_activated_fs(binds, true)

    assert_equal ['tcp://0.0.0.0:3000'], result
  end

  def test_synthesize_binds_from_activated_fds_non_matching_together
    binds = ['tcp://0.0.0.0:3000']
    sockets = {['tcp', '0.0.0.0', '5000'] => nil}
    @binder.instance_variable_set(:@activated_sockets, sockets)
    result = @binder.synthesize_binds_from_activated_fs(binds, false)

    assert_equal ['tcp://0.0.0.0:3000', 'tcp://0.0.0.0:5000'], result
  end

  def test_synthesize_binds_from_activated_fds_non_matching_only
    binds = ['tcp://0.0.0.0:3000']
    sockets = {['tcp', '0.0.0.0', '5000'] => nil}
    @binder.instance_variable_set(:@activated_sockets, sockets)
    result = @binder.synthesize_binds_from_activated_fs(binds, true)

    assert_equal ['tcp://0.0.0.0:5000'], result
  end

  def test_synthesize_binds_from_activated_fds_complex_binds
    binds = [
      'tcp://0.0.0.0:3000',
      'ssl://192.0.2.100:5000',
      'ssl://192.0.2.101:5000?no_tlsv1=true',
      'unix:///run/puma.sock'
    ]
    sockets = {
      ['tcp', '0.0.0.0', '5000'] => nil,
      ['tcp', '192.0.2.100', '5000'] => nil,
      ['tcp', '192.0.2.101', '5000'] => nil,
      ['unix', '/run/puma.sock'] => nil
    }
    @binder.instance_variable_set(:@activated_sockets, sockets)
    result = @binder.synthesize_binds_from_activated_fs(binds, false)

    expected = ['tcp://0.0.0.0:3000', 'ssl://192.0.2.100:5000', 'ssl://192.0.2.101:5000?no_tlsv1=true', 'unix:///run/puma.sock', 'tcp://0.0.0.0:5000']
    assert_equal expected, result
  end

  def test_localhost_addresses_dont_alter_listeners_for_tcp_addresses
    @binder.parse ["tcp://localhost:0"], @events

    assert_empty @binder.listeners
  end

  def test_home_alters_listeners_for_tcp_addresses
    port = UniquePort.call
    @binder.parse ["tcp://127.0.0.1:#{port}"], @events

    assert_equal "tcp://127.0.0.1:#{port}", @binder.listeners[0][0]
    assert_kind_of TCPServer, @binder.listeners[0][1]
  end

  def test_connected_ports
    ports = (1..3).map { |_| UniquePort.call }

    @binder.parse(ports.map { |p| "tcp://localhost:#{p}" }, @events)

    assert_equal ports, @binder.connected_ports
  end

  def test_localhost_addresses_dont_alter_listeners_for_ssl_addresses
    skip_unless :ssl
    @binder.parse ["ssl://localhost:0?#{ssl_query}"], @events

    assert_empty @binder.listeners
  end

  def test_home_alters_listeners_for_ssl_addresses
    skip_unless :ssl
    port = UniquePort.call
    @binder.parse ["ssl://127.0.0.1:#{port}?#{ssl_query}"], @events

    assert_equal "ssl://127.0.0.1:#{port}?#{ssl_query}", @binder.listeners[0][0]
    assert_kind_of TCPServer, @binder.listeners[0][1]
  end

  def test_correct_zero_port
    @binder.parse ["tcp://localhost:0"], @events

    m = %r!http://127.0.0.1:(\d+)!.match(@events.stdout.string)
    port = m[1].to_i

    refute_equal 0, port
  end

  def test_correct_zero_port_ssl
    skip_unless :ssl

    ssl_regex = %r!ssl://127.0.0.1:(\d+)!

    @binder.parse ["ssl://localhost:0?#{ssl_query}"], @events

    port = ssl_regex.match(@events.stdout.string)[1].to_i

    refute_equal 0, port
  end

  def test_logs_all_localhost_bindings
    @binder.parse ["tcp://localhost:0"], @events

    assert_match %r!http://127.0.0.1:(\d+)!, @events.stdout.string
    if Socket.ip_address_list.any? {|i| i.ipv6_loopback? }
      assert_match %r!http://\[::1\]:(\d+)!, @events.stdout.string
    end
  end

  def test_logs_all_localhost_bindings_ssl
    skip_unless :ssl

    @binder.parse ["ssl://localhost:0?#{ssl_query}"], @events

    assert_match %r!ssl://127.0.0.1:(\d+)!, @events.stdout.string
    if Socket.ip_address_list.any? {|i| i.ipv6_loopback? }
      assert_match %r!ssl://\[::1\]:(\d+)!, @events.stdout.string
    end
  end

  def test_allows_both_ssl_and_tcp
    assert_parsing_logs_uri [:ssl, :tcp]
  end

  def test_allows_both_unix_and_tcp
    skip_if :jruby # Undiagnosed thread race. TODO fix
    assert_parsing_logs_uri [:unix, :tcp]
  end

  def test_allows_both_tcp_and_unix
    assert_parsing_logs_uri [:tcp, :unix]
  end

  def test_pre_existing_unix
    skip_unless :unix

    unix_path = tmp_path('.sock')
    File.open(unix_path, mode: 'wb') { |f| f.puts 'pre existing' }
    @binder.parse ["unix://#{unix_path}"], @events

    assert_match %r!unix://#{unix_path}!, @events.stdout.string

    refute_includes @binder.unix_paths, unix_path

    @binder.close_listeners

    assert File.exist?(unix_path)

  ensure
    if UNIX_SKT_EXIST
      File.unlink unix_path if File.exist? unix_path
    end
  end

  def test_binder_parses_nil_low_latency
    skip_if :jruby
    @binder.parse ["tcp://0.0.0.0:0?low_latency"], @events

    socket = @binder.listeners.first.last

    assert socket.getsockopt(Socket::IPPROTO_TCP, Socket::TCP_NODELAY).bool
  end

  def test_binder_parses_true_low_latency
    skip_if :jruby
    @binder.parse ["tcp://0.0.0.0:0?low_latency=true"], @events

    socket = @binder.listeners.first.last

    assert socket.getsockopt(Socket::IPPROTO_TCP, Socket::TCP_NODELAY).bool
  end

  def test_binder_parses_false_low_latency
    skip_if :jruby
    @binder.parse ["tcp://0.0.0.0:0?low_latency=false"], @events

    socket = @binder.listeners.first.last

    refute socket.getsockopt(Socket::IPPROTO_TCP, Socket::TCP_NODELAY).bool
  end

  def test_binder_parses_tlsv1_disabled
    skip_unless :ssl
    @binder.parse ["ssl://0.0.0.0:0?#{ssl_query}&no_tlsv1=true"], @events

    assert ssl_context_for_binder.no_tlsv1
  end

  def test_binder_parses_tlsv1_enabled
    skip_unless :ssl
    @binder.parse ["ssl://0.0.0.0:0?#{ssl_query}&no_tlsv1=false"], @events

    refute ssl_context_for_binder.no_tlsv1
  end

  def test_binder_parses_tlsv1_tlsv1_1_unspecified_defaults_to_enabled
    skip_unless :ssl
    @binder.parse ["ssl://0.0.0.0:0?#{ssl_query}"], @events

    refute ssl_context_for_binder.no_tlsv1
    refute ssl_context_for_binder.no_tlsv1_1
  end

  def test_binder_parses_tlsv1_1_disabled
    skip_unless :ssl
    @binder.parse ["ssl://0.0.0.0:0?#{ssl_query}&no_tlsv1_1=true"], @events

    assert ssl_context_for_binder.no_tlsv1_1
  end

  def test_binder_parses_tlsv1_1_enabled
    skip_unless :ssl
    @binder.parse ["ssl://0.0.0.0:0?#{ssl_query}&no_tlsv1_1=false"], @events

    refute ssl_context_for_binder.no_tlsv1_1
  end

  def test_env_contains_protoenv
    skip_unless :ssl
    @binder.parse ["ssl://localhost:0?#{ssl_query}"], @events

    env_hash = @binder.envs[@binder.ios.first]

    @binder.proto_env.each do |k,v|
      assert env_hash[k] == v
    end
  end

  def test_env_contains_stderr
    skip_unless :ssl
    @binder.parse ["ssl://localhost:0?#{ssl_query}"], @events

    env_hash = @binder.envs[@binder.ios.first]

    assert_equal @events.stderr, env_hash["rack.errors"]
  end

  def test_ssl_binder_sets_backlog
    skip_unless :ssl

    host = '127.0.0.1'
    port = UniquePort.call
    tcp_server = TCPServer.new(host, port)
    tcp_server.define_singleton_method(:listen) do |backlog|
      Thread.current[:backlog] = backlog
      super(backlog)
    end

    TCPServer.stub(:new, tcp_server) do
      @binder.parse ["ssl://#{host}:#{port}?#{ssl_query}&backlog=2048"], @events
    end

    assert_equal 2048, Thread.current[:backlog]
  end

  def test_close_calls_close_on_ios
    @mocked_ios = [Minitest::Mock.new, Minitest::Mock.new]
    @mocked_ios.each { |m| m.expect(:close, true) }
    @binder.ios = @mocked_ios

    @binder.close

    assert @mocked_ios.map(&:verify).all?
  end

  def test_redirects_for_restart_creates_a_hash
    @binder.parse ["tcp://127.0.0.1:0"], @events

    result = @binder.redirects_for_restart
    ios = @binder.listeners.map { |_l, io| io.to_i }

    ios.each { |int| assert_equal int, result[int] }
    assert result[:close_others]
  end

  def test_redirects_for_restart_env
    @binder.parse ["tcp://127.0.0.1:0"], @events

    result = @binder.redirects_for_restart_env

    @binder.listeners.each_with_index do |l, i|
      assert_equal "#{l[1].to_i}:#{l[0]}", result["PUMA_INHERIT_#{i}"]
    end
  end

  def test_close_listeners_closes_ios
    @binder.parse ["tcp://127.0.0.1:#{UniquePort.call}"], @events

    refute @binder.listeners.any? { |_l, io| io.closed? }

    @binder.close_listeners

    assert @binder.listeners.all? { |_l, io| io.closed? }
  end

  def test_close_listeners_closes_ios_unless_closed?
    @binder.parse ["tcp://127.0.0.1:0"], @events

    bomb = @binder.listeners.first[1]
    bomb.close
    def bomb.close; raise "Boom!"; end # the bomb has been planted

    assert @binder.listeners.any? { |_l, io| io.closed? }

    @binder.close_listeners

    assert @binder.listeners.all? { |_l, io| io.closed? }
  end

  def test_listeners_file_unlink_if_unix_listener
    skip_unless :unix

    unix_path = tmp_path('.sock')
    @binder.parse ["unix://#{unix_path}"], @events
    assert File.socket?(unix_path)

    @binder.close_listeners
    refute File.socket?(unix_path)
  end

  def test_import_from_env_listen_inherit
    @binder.parse ["tcp://127.0.0.1:0"], @events
    removals = @binder.create_inherited_fds(@binder.redirects_for_restart_env)

    @binder.listeners.each do |l, io|
      assert_equal io.to_i, @binder.inherited_fds[l]
    end
    assert_includes removals, "PUMA_INHERIT_0"
  end

  # Socket activation tests. We have to skip all of these on non-UNIX platforms
  # because the check that we do in the code only works if you support UNIX sockets.
  # This is OK, because systemd obviously only works on Linux.
  def test_socket_activation_tcp
    skip_unless :unix
    url = "127.0.0.1"
    port = UniquePort.call
    sock = Addrinfo.tcp(url, port).listen
    assert_activates_sockets(url: url, port: port, sock: sock)
  end

  def test_socket_activation_tcp_ipv6
    skip_unless :unix
    url = "::"
    port = UniquePort.call
    sock = Addrinfo.tcp(url, port).listen
    assert_activates_sockets(url: url, port: port, sock: sock)
  end

  def test_socket_activation_unix
    skip_if :jruby # Failing with what I think is a JRuby bug
    skip_unless :unix

    state_path = tmp_path('.state')
    sock = Addrinfo.unix(state_path).listen
    assert_activates_sockets(path: state_path, sock: sock)
  ensure
    File.unlink(state_path) rescue nil # JRuby race?
  end

  def test_rack_multithread_default_configuration
    binder = Puma::Binder.new(@events)

    assert binder.proto_env["rack.multithread"]
  end

  def test_rack_multithread_custom_configuration
    conf = Puma::Configuration.new(max_threads: 1)

    binder = Puma::Binder.new(@events, conf)

    refute binder.proto_env["rack.multithread"]
  end

  def test_rack_multiprocess_default_configuration
    binder = Puma::Binder.new(@events)

    refute binder.proto_env["rack.multiprocess"]
  end

  def test_rack_multiprocess_custom_configuration
    conf = Puma::Configuration.new(workers: 1)

    binder = Puma::Binder.new(@events, conf)

    assert binder.proto_env["rack.multiprocess"]
  end

  private

  def assert_activates_sockets(path: nil, port: nil, url: nil, sock: nil)
    hash = { "LISTEN_FDS" => 1, "LISTEN_PID" => $$ }
    @events.instance_variable_set(:@debug, true)

    @binder.instance_variable_set(:@sock_fd, sock.fileno)
    def @binder.socket_activation_fd(int); @sock_fd; end
    @result = @binder.create_activated_fds(hash)

    url = "[::]" if url == "::"
    ary = path ? [:unix, path] : [:tcp, url, port]

    assert_kind_of TCPServer, @binder.activated_sockets[ary]
    assert_match "Registered #{ary.join(":")} for activation from LISTEN_FDS", @events.stdout.string
    assert_equal ["LISTEN_FDS", "LISTEN_PID"], @result
  end

  def assert_parsing_logs_uri(order = [:unix, :tcp])
    skip MSG_UNIX if order.include?(:unix) && !UNIX_SKT_EXIST
    skip_unless :ssl

    unix_path = tmp_path('.sock')
    prepared_paths = {
        ssl: "ssl://127.0.0.1:#{UniquePort.call}?#{ssl_query}",
        tcp: "tcp://127.0.0.1:#{UniquePort.call}",
        unix: "unix://#{unix_path}"
      }

    expected_logs = prepared_paths.dup.tap do |logs|
      logs[:tcp] = logs[:tcp].gsub('tcp://', 'http://')
    end

    tested_paths = [prepared_paths[order[0]], prepared_paths[order[1]]]

    @binder.parse tested_paths, @events
    stdout = @events.stdout.string

    order.each do |prot|
      assert_match expected_logs[prot], stdout
    end
  ensure
    @binder.close_listeners if order.include?(:unix) && UNIX_SKT_EXIST
  end
end

class TestBinderJRuby < TestBinderBase
  def test_binder_parses_jruby_ssl_options
    skip_unless :ssl

    keystore = File.expand_path "../../examples/puma/keystore.jks", __FILE__
    ssl_cipher_list = "TLS_DHE_RSA_WITH_AES_128_CBC_SHA,TLS_ECDHE_RSA_WITH_AES_128_GCM_SHA256"

    @binder.parse ["ssl://0.0.0.0:8080?#{ssl_query}"], @events

    assert_equal keystore, ssl_context_for_binder.keystore
    assert_equal ssl_cipher_list, ssl_context_for_binder.ssl_cipher_list
  end
end if ::Puma::IS_JRUBY

class TestBinderMRI < TestBinderBase
  def test_binder_parses_ssl_cipher_filter
    skip_unless :ssl

    ssl_cipher_filter = "AES@STRENGTH"

    @binder.parse ["ssl://0.0.0.0?#{ssl_query}&ssl_cipher_filter=#{ssl_cipher_filter}"], @events

    assert_equal ssl_cipher_filter, ssl_context_for_binder.ssl_cipher_filter
  end

  def test_binder_parses_ssl_verification_flags_one
    skip_unless :ssl

    input = "&verification_flags=TRUSTED_FIRST"

    @binder.parse ["ssl://0.0.0.0?#{ssl_query}#{input}"], @events

    assert_equal 0x8000, ssl_context_for_binder.verification_flags
  end

  def test_binder_parses_ssl_verification_flags_multiple
    skip_unless :ssl

    input = "&verification_flags=TRUSTED_FIRST,NO_CHECK_TIME"

    @binder.parse ["ssl://0.0.0.0?#{ssl_query}#{input}"], @events

    assert_equal 0x8000 | 0x200000, ssl_context_for_binder.verification_flags
  end
end unless ::Puma::IS_JRUBY
