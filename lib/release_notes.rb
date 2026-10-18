require 'json'
require 'net/http'
require 'openssl'
require 'base64'
require 'uri'
require_relative 'locales'

module ReleaseNotes
  class Error < StandardError; end

  # Browser text inputs may collapse pasted line breaks. Tags delimit blocks even
  # when inline; do not attempt to reconstruct line breaks within the notes.
  def self.normalize(input)
    text = input.sub(/\A\uFEFF/, '').strip
    fence = text.match(/\A```(?:text)?[ \t]*(?:\r?\n|[ \t]+)(.*?)\s*```\z/m)
    text = fence[1] if fence
    text.gsub(%r{[ \t]*(</?[A-Za-z]{2,3}(?:-[A-Za-z0-9]{2,8})*>)[ \t]*}) { "\n#{$1}\n" }
  end

  def self.parse(input)
    notes = {}
    locale = nil
    lines = []
    normalize(input).each_line.with_index(1) do |line, number|
      tag = line.strip.match(%r{\A<(/?)([A-Za-z]{2,3}(?:-[A-Za-z0-9]{2,8})*)>\z})
      if tag
        closing, code = tag.captures
        if closing.empty?
          raise Error, "Line #{number}: nested or unclosed locale" if locale
          raise Error, "Duplicate locale: #{code}" if notes.key?(code)
          locale, lines = code, []
        else
          raise Error, "Line #{number}: mismatched closing locale #{code}" unless locale == code
          text = lines.join.strip
          raise Error, "#{code}: notes must contain 1–4000 characters" unless (1..4000).cover?(text.length)
          notes[code] = text
          locale = nil
        end
      elsif locale
        raise Error, "Line #{number}: malformed locale tag" if line.strip.match?(%r{\A</?[A-Za-z][^>]*>\z})
        lines << line
      elsif !line.strip.empty?
        raise Error, "Line #{number}: expected an opening locale tag"
      end
    end
    raise Error, "Unclosed locale: #{locale}" if locale
    raise Error, 'No release notes found' if notes.empty?
    notes
  end

  def self.map(notes, overrides = {})
    overrides.each do |source, target|
      raise Error, "Invalid mapping for #{source}" unless target.nil? || APPLE_LOCALES.include?(target)
    end
    mapping = MAPPING.merge(overrides)
    result, sources = {}, {}
    notes.each do |source, text|
      raise Error, "Unknown Google Play locale: #{source}" unless mapping.key?(source)
      target = mapping[source]
      unless target
        puts "SKIP #{source}: no App Store equivalent"
        next
      end
      puts "MAP #{source} -> #{target}"
      if result.key?(target) && result[target] != text
        raise Error, "Conflicting notes for #{target}: #{sources[target]} and #{source}; use --locale-map to skip or remap a source"
      end
      result[target], sources[target] = text, source
    end
    raise Error, 'No supported release notes remain' if result.empty?
    result
  end

  class Client
    BASE = 'https://api.appstoreconnect.apple.com'
    def initialize(key_id, issuer_id, key_file)
      @key_id, @issuer_id = key_id, issuer_id
      @key = OpenSSL::PKey.read(File.read(key_file))
      raise Error, 'Expected a P-256 EC private key' unless @key.is_a?(OpenSSL::PKey::EC) && @key.private? && @key.group.curve_name == 'prime256v1'
    end

    def token
      return @token if @expires && Time.now.to_i < @expires - 30
      @expires = Time.now.to_i + 600
      encode = ->(value) { Base64.urlsafe_encode64(value, padding: false) }
      header = encode.call(JSON.generate(alg: 'ES256', kid: @key_id, typ: 'JWT'))
      payload = encode.call(JSON.generate(iss: @issuer_id, iat: Time.now.to_i, exp: @expires, aud: 'appstoreconnect-v1'))
      body = "#{header}.#{payload}"
      signature = OpenSSL::ASN1.decode(@key.sign('SHA256', body)).value.map { |n| n.value.to_i.to_s(16).rjust(64, '0') }.join
      @token = "#{body}.#{encode.call([signature].pack('H*'))}"
    end

    def request(method, path, body = nil)
      uri = URI.join(BASE, path)
      raise Error, 'Refusing an unexpected API origin' unless uri.scheme == 'https' && uri.host == 'api.appstoreconnect.apple.com' && uri.port == 443
      4.times do |attempt|
        req = (method == :get ? Net::HTTP::Get : Net::HTTP::Patch).new(uri)
        req['Authorization'] = "Bearer #{token}"
        req['Content-Type'] = 'application/json'
        req.body = JSON.generate(body) if body
        response = Net::HTTP.start(uri.host, uri.port, use_ssl: true, open_timeout: 15, read_timeout: 60) { |http| http.request(req) }
        if response.code.to_i == 429 || response.code.to_i >= 500
          if attempt < 3
            sleep([response['Retry-After'].to_i, 2**attempt].max.clamp(1, 30))
            next
          end
        end
        unless response.is_a?(Net::HTTPSuccess)
          # Deliberately omit response bodies, which may echo submitted data.
          raise Error, "Apple API #{method.to_s.upcase} #{uri.path}: HTTP #{response.code}"
        end
        return JSON.parse(response.body)
      end
    rescue SocketError, Timeout::Error, IOError, SystemCallError, OpenSSL::OpenSSLError => e
      raise Error, "Apple API transport failure (#{e.class}); rerun to reconcile any completed updates"
    end

    def list(path, filters = {})
      query = URI.encode_www_form(filters.merge('limit' => '200'))
      path = "#{path}?#{query}"
      data = []
      while path
        page = request(:get, path)
        data.concat(page.fetch('data'))
        path = page.fetch('links', {})['next']
      end
      data
    end
  end

  def self.publish(client, bundle_id, version_string, notes, apply: false)
    apps = client.list('/v1/apps', 'filter[bundleId]' => bundle_id)
    raise Error, "Expected one app for #{bundle_id}, found #{apps.length}" unless apps.length == 1
    versions = client.list("/v1/apps/#{apps.first.fetch('id')}/appStoreVersions", 'filter[versionString]' => version_string, 'filter[platform]' => 'IOS')
    raise Error, "Expected one existing iOS version #{version_string}, found #{versions.length}" unless versions.length == 1
    version = versions.first
    puts "Version #{version_string}: #{version.fetch('attributes')['appStoreState']}"
    localizations = client.list("/v1/appStoreVersions/#{version.fetch('id')}/appStoreVersionLocalizations")
    existing = localizations.to_h { |loc| [loc.fetch('attributes').fetch('locale'), loc] }
    plan = notes.select do |locale, _|
      puts "SKIP #{locale}: not present on this version" unless existing.key?(locale)
      existing.key?(locale)
    end
    raise Error, 'No matching existing localizations' if plan.empty?
    failures = []
    plan.each do |locale, text|
      loc = existing.fetch(locale)
      if loc.fetch('attributes')['whatsNew'] == text
        puts "UNCHANGED #{locale}"
        next
      end
      unless apply
        puts "WOULD UPDATE #{locale} (#{text.length} characters)"
        next
      end
      begin
        client.request(:patch, "/v1/appStoreVersionLocalizations/#{loc.fetch('id')}", data: { type: 'appStoreVersionLocalizations', id: loc.fetch('id'), attributes: { whatsNew: text } })
        puts "UPDATED #{locale}"
      rescue Error => e
        warn "FAILED #{locale}: #{e.message}"
        failures << locale
      end
    end
    raise Error, "Updates failed for: #{failures.join(', ')}; earlier successful updates remain applied" unless failures.empty?
    puts(apply ? 'Complete.' : 'Dry run complete. Pass --apply to write.')
  end
end
