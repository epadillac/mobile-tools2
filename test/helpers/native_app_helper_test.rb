require "test_helper"

class NativeAppHelperTest < ActiveSupport::TestCase
  include NativeAppHelper

  # Real-world UAs we expect to see in the wild. Add new ones here whenever
  # the wrapper team ships a new platform/version combination.
  IPAD_RUBY_NATIVE = "Mozilla/5.0 (iPad; CPU OS 18_7 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Ruby Native iOS/1.0.0 RubyNative/0.9.0".freeze
  IPHONE_RUBY_NATIVE = "Mozilla/5.0 (iPhone; CPU iPhone OS 17_5 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Ruby Native iOS/1.2.3 RubyNative/0.9.0".freeze
  ANDROID_RUBY_NATIVE = "Mozilla/5.0 (Linux; Android 14; Pixel 8) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0 Ruby Native Android/2.1.0 RubyNative/0.9.1".freeze
  HOTWIRE_NATIVE_IOS = "Mozilla/5.0 (iPhone; CPU iPhone OS 17_5 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Turbo Native iOS".freeze
  PLAIN_DESKTOP_CHROME = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36".freeze
  EMPTY_UA = "".freeze

  # The helper reads UA off the controller's `request` object, so we stub one
  # in for each test by overriding `request` in the include scope.
  def stub_request(user_agent)
    @stubbed_request = Struct.new(:user_agent).new(user_agent)
  end

  def request
    @stubbed_request
  end

  # Match the controller-side helper that turbo-rails provides; we don't pull
  # in the gem here, so stub it for native_shell? composition tests.
  def hotwire_native_app?
    request.user_agent.to_s.include?("Turbo Native")
  end

  test "detects RubyNative on iPad" do
    stub_request(IPAD_RUBY_NATIVE)
    assert ruby_native_app?
    assert_equal "iOS", ruby_native_platform
    assert_equal "1.0.0", ruby_native_app_version
    assert_equal "0.9.0", ruby_native_gem_version
    assert native_shell?
  end

  test "detects RubyNative on iPhone with different versions" do
    stub_request(IPHONE_RUBY_NATIVE)
    assert ruby_native_app?
    assert_equal "iOS", ruby_native_platform
    assert_equal "1.2.3", ruby_native_app_version
    assert_equal "0.9.0", ruby_native_gem_version
  end

  test "detects RubyNative on Android" do
    stub_request(ANDROID_RUBY_NATIVE)
    assert ruby_native_app?
    assert_equal "Android", ruby_native_platform
    assert_equal "2.1.0", ruby_native_app_version
    assert_equal "0.9.1", ruby_native_gem_version
  end

  test "treats Hotwire Native as a native shell but not a RubyNative app" do
    stub_request(HOTWIRE_NATIVE_IOS)
    assert_not ruby_native_app?, "Turbo Native UA must not be misclassified as RubyNative"
    assert_nil ruby_native_platform
    assert_nil ruby_native_app_version
    assert_nil ruby_native_gem_version
    assert native_shell?, "native_shell? should be true for Turbo Native via hotwire_native_app?"
  end

  test "rejects plain desktop browser UAs" do
    stub_request(PLAIN_DESKTOP_CHROME)
    assert_not ruby_native_app?
    assert_not native_shell?
    assert_nil ruby_native_platform
    assert_nil ruby_native_app_version
    assert_nil ruby_native_gem_version
  end

  test "handles missing user agent header" do
    stub_request(nil)
    assert_not ruby_native_app?
    assert_nil ruby_native_platform
    assert_nil ruby_native_app_version
    assert_nil ruby_native_gem_version
  end

  test "handles empty user agent header" do
    stub_request(EMPTY_UA)
    assert_not ruby_native_app?
    assert_nil ruby_native_platform
  end

  test "matches RubyNative even when only the gem-version stamp is present" do
    # Defensive: if the wrapper ever drops the "Ruby Native iOS/X.Y.Z" segment
    # but keeps "RubyNative/X.Y.Z", we still want detection to fire so the UI
    # treats the request as a native shell. Platform/app-version will be nil.
    stub_request("Mozilla/5.0 SomeWebKit RubyNative/0.7.4")
    assert ruby_native_app?
    assert_nil ruby_native_platform, "platform requires the 'Ruby Native <Platform>/...' segment"
    assert_nil ruby_native_app_version
    assert_equal "0.7.4", ruby_native_gem_version
  end
end
