require 'minitest/autorun'
require_relative '../lib/release_notes'

class ReleaseNotesTest < Minitest::Test
  def test_multiline_bom_crlf_and_literal_ampersands
    assert_equal({ 'en-US' => "Fix & improve\r\nSecond line" }, ReleaseNotes.parse("\uFEFF<en-US>\r\nFix & improve\r\nSecond line\r\n</en-US>\r\n"))
  end

  def test_inline_tags_from_single_line_pipeline_input
    assert_equal({ 'en-US' => 'Fix & improve', 'fr-FR' => 'Corrections' },
      ReleaseNotes.parse('<en-US> Fix & improve </en-US> <fr-FR> Corrections </fr-FR>'))
  end

  def test_copied_markdown_fence
    expected = { 'en-US' => "First line\nSecond line" }
    assert_equal expected, ReleaseNotes.parse("```text\n<en-US>\nFirst line\nSecond line\n</en-US>\n```")
    assert_equal({ 'en-US' => 'Fixes' }, ReleaseNotes.parse('```text <en-US> Fixes </en-US> ```'))
    assert_equal({ 'en-US' => 'Fixes' }, ReleaseNotes.parse("```\n<en-US>Fixes</en-US>\n```"))
  end

  def test_rejects_invalid_inline_input
    ['<en-US></en-US>', '<en-US>x</fr-FR>', '<en-US>x<fr-FR>y</fr-FR></en-US>',
     '<en-US>x</en-US><en-US>y</en-US>', 'outside <en-US>x</en-US>',
     '<en-US>x</en-US> outside', '<en-US>x</en-US><bad_tag>'].each do |input|
      assert_raises(ReleaseNotes::Error) { ReleaseNotes.parse(input) }
    end
  end

  def test_rejects_invalid_input
    ['', '<en-US>', "<en-US>\nx\n</de-DE>", "<en-US>\n</en-US>", "<en-US>\nx\n<de-DE>\n", "outside\n", "<en-US>\n#{'x' * 4001}\n</en-US>", "<en-US>\nx\n</en-US>\n<en-US>\ny\n</en-US>"].each do |input|
      assert_raises(ReleaseNotes::Error) { ReleaseNotes.parse(input) }
    end
  end

  def test_complete_mapping_and_apple_coverage
    assert_equal ReleaseNotes::GOOGLE_LOCALES.sort, ReleaseNotes::MAPPING.keys.sort
    assert_empty ReleaseNotes::APPLE_LOCALES - ReleaseNotes::MAPPING.values.compact
  end

  def test_collisions_and_overrides
    capture_io do
      assert_raises(ReleaseNotes::Error) { ReleaseNotes.map('es-419' => 'A', 'es-US' => 'B') }
      assert_equal({ 'es-MX' => 'A' }, ReleaseNotes.map({ 'es-419' => 'A', 'es-US' => 'B' }, 'es-US' => nil))
      assert_equal({ 'zh-Hant' => 'A' }, ReleaseNotes.map('zh-HK' => 'A', 'zh-TW' => 'A'))
      assert_raises(ReleaseNotes::Error) { ReleaseNotes.map('xx-XX' => 'A') }
      assert_raises(ReleaseNotes::Error) { ReleaseNotes.map('af' => 'A') }
    end
  end

  def test_jwt_signature
    require 'tempfile'
    key = OpenSSL::PKey::EC.generate('prime256v1')
    Tempfile.create('key') do |file|
      file.write(key.to_pem)
      file.flush
      client = ReleaseNotes::Client.new('KEY', 'ISSUER', file.path)
      head, payload, sig = client.token.split('.')
      decoded = JSON.parse(Base64.urlsafe_decode64(payload))
      assert_equal 'ISSUER', decoded['iss']
      assert_equal 'appstoreconnect-v1', decoded['aud']
      raw = Base64.urlsafe_decode64(sig)
      assert_equal 64, raw.bytesize
      integers = raw.unpack('H*').first.scan(/.{64}/).map { |n| OpenSSL::ASN1::Integer.new(OpenSSL::BN.new(n, 16)) }
      assert key.verify('SHA256', OpenSSL::ASN1::Sequence.new(integers).to_der, "#{head}.#{payload}")
    end
  end

  def test_pagination_filters_and_origin_guard
    client = ReleaseNotes::Client.allocate
    paths = []
    client.define_singleton_method(:request) do |_method, path|
      paths << path
      paths.length == 1 ? { 'data' => [1], 'links' => { 'next' => '/v1/apps?cursor=2' } } : { 'data' => [2], 'links' => {} }
    end
    assert_equal [1, 2], client.list('/v1/apps', 'filter[bundleId]' => 'com.example.app')
    assert_includes paths.first, 'filter%5BbundleId%5D=com.example.app'
    assert_equal '/v1/apps?cursor=2', paths.last
    assert_raises(ReleaseNotes::Error) { ReleaseNotes::Client.allocate.request(:get, 'https://example.com/steal') }
  end

  class FakeClient
    attr_reader :writes
    def initialize(fail_locale = nil)
      @writes, @fail_locale = [], fail_locale
    end
    def list(path, _filters = {})
      case path
      when '/v1/apps' then [{ 'id' => 'app' }]
      when '/v1/apps/app/appStoreVersions' then [{ 'id' => 'version', 'attributes' => { 'appStoreState' => 'PREPARE_FOR_SUBMISSION' } }]
      else
        %w[en-US de-DE].map { |l| { 'id' => l, 'attributes' => { 'locale' => l, 'whatsNew' => 'Old' } } }
      end
    end
    def request(_method, path, body)
      raise ReleaseNotes::Error, 'HTTP 409' if path.end_with?(@fail_locale.to_s) && @fail_locale
      @writes << body
    end
  end

  def test_dry_run_existing_only_and_unchanged
    client = FakeClient.new
    capture_io do
      ReleaseNotes.publish(client, 'bundle', '1.0', { 'en-US' => 'New', 'fr-FR' => 'New' })
      assert_empty client.writes
      ReleaseNotes.publish(client, 'bundle', '1.0', { 'en-US' => 'Old', 'de-DE' => 'New', 'fr-FR' => 'New' }, apply: true)
    end
    assert_equal ['de-DE'], client.writes.map { |body| body[:data][:id] }
    assert_equal({ whatsNew: 'New' }, client.writes.first[:data][:attributes])
  end

  def test_partial_failure_is_reported_and_remaining_locales_attempted
    client = FakeClient.new('en-US')
    capture_io do
      assert_raises(ReleaseNotes::Error) do
        ReleaseNotes.publish(client, 'bundle', '1.0', { 'en-US' => 'New', 'de-DE' => 'New' }, apply: true)
      end
    end
    assert_equal 1, client.writes.length
  end
end
