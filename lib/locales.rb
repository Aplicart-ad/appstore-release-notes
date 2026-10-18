# Sources and policies are documented in README.md. nil means Apple has no equivalent.
module ReleaseNotes
  APPLE_LOCALES = %w[ar-SA ca cs da de-DE el en-AU en-CA en-GB en-US es-ES es-MX fi fr-CA fr-FR he hi hr hu id it ja ko ms nl-NL no pl pt-BR pt-PT ro ru sk sv th tr uk vi zh-Hans zh-Hant].freeze
  GOOGLE_LOCALES = %w[af sq am ar hy-AM az-AZ bn-BD eu-ES be bg my-MM ca zh-HK zh-CN zh-TW hr cs-CZ da-DK nl-NL en-AU en-CA en-US en-GB en-IN en-SG en-ZA et fil fi-FI fr-CA fr-FR gl-ES ka-GE de-DE el-GR gu iw-IL hi-IN hu-HU is-IS id it-IT ja-JP kn-IN kk km-KH ko-KR ky-KG lo-LA lv lt mk-MK ms-MY ms ml-IN mr-IN mn-MN ne-NP no-NO fa fa-AE fa-AF fa-IR pl-PL pt-BR pt-PT pa ro rm ru-RU sr si-LK sk sl es-419 es-ES es-US sw sv-SE ta-IN te-IN th tr-TR uk ur vi].freeze
  MAPPING = GOOGLE_LOCALES.to_h { |locale| [locale, APPLE_LOCALES.include?(locale) ? locale : nil] }.merge(
    'ar' => 'ar-SA', 'zh-HK' => 'zh-Hant', 'zh-CN' => 'zh-Hans', 'zh-TW' => 'zh-Hant',
    'cs-CZ' => 'cs', 'da-DK' => 'da', 'en-IN' => 'en-GB', 'en-SG' => 'en-GB', 'en-ZA' => 'en-GB',
    'fi-FI' => 'fi', 'el-GR' => 'el', 'iw-IL' => 'he', 'hi-IN' => 'hi', 'hu-HU' => 'hu',
    'it-IT' => 'it', 'ja-JP' => 'ja', 'ko-KR' => 'ko', 'ms-MY' => 'ms', 'no-NO' => 'no',
    'pl-PL' => 'pl', 'ru-RU' => 'ru', 'es-419' => 'es-MX', 'es-US' => 'es-MX',
    'sv-SE' => 'sv', 'tr-TR' => 'tr'
  ).freeze
end
