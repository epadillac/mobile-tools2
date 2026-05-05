module NativeAppHelper
  # Detect requests coming from the RubyNative iOS/Android wrapper.
  # We do our own UA matching here instead of leaning on the gem's
  # `native_app?` because that helper's behavior changed between versions
  # (we're on ~> 0.5.0, the helper code in upstream 0.9.0 reads differently)
  # and we send a UA shaped like:
  #
  #   Mozilla/5.0 (iPad; CPU OS 18_7 like Mac OS X) AppleWebKit/605.1.15 \
  #   (KHTML, like Gecko) Ruby Native iOS/1.0.0 RubyNative/0.9.0
  #
  # Two distinct markers — `Ruby Native <Platform>/<app-ver>` and
  # `RubyNative/<gem-ver>` — show up in every request from the wrapper.
  # Match either, so the check survives small wrapper changes.

  RUBY_NATIVE_RE      = /\bRubyNative\/([\d.]+)/.freeze
  RUBY_NATIVE_APP_RE  = /\bRuby Native (iOS|iPadOS|Android|Mac(?:OS)?|Windows)\/([\d.]+)/i.freeze

  # Returns true when the request comes from a RubyNative wrapper.
  # Catches both the "Ruby Native iOS/1.0.0" segment and the "RubyNative/x.y.z"
  # gem-version stamp; either is sufficient.
  def ruby_native_app?
    ua = request.user_agent.to_s
    ua.match?(RUBY_NATIVE_RE) || ua.match?(RUBY_NATIVE_APP_RE)
  end

  # Returns the platform string ("iOS", "Android", "Mac", ...) or nil.
  # Useful when you want to render slightly different UI per platform
  # (e.g. iOS share sheet vs. Android intent).
  def ruby_native_platform
    return nil unless request.user_agent.to_s =~ RUBY_NATIVE_APP_RE
    $1
  end

  # Returns the wrapper *app* version (e.g. "1.0.0") — the version of the
  # iOS/Android binary your users have installed. nil if not present.
  def ruby_native_app_version
    return nil unless request.user_agent.to_s =~ RUBY_NATIVE_APP_RE
    $2
  end

  # Returns the embedded RubyNative *gem* version (e.g. "0.9.0") — the
  # version of the JS bridge the wrapper ships with. nil if not present.
  def ruby_native_gem_version
    return nil unless request.user_agent.to_s =~ RUBY_NATIVE_RE
    $1
  end

  # Convenience: combines the existing turbo-native check with our
  # RubyNative check. Returns true for ANY embedded webview (Hotwire
  # Native or RubyNative), false for plain browsers. Use this when you
  # just want to know "is this a native shell?" and don't care which one.
  def native_shell?
    (respond_to?(:hotwire_native_app?) && hotwire_native_app?) || ruby_native_app?
  end
end
