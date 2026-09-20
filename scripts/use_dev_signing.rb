# Points the Debug configuration at the local development certificate, so a
# rebuild keeps the same code-signing identity and therefore keeps its TCC
# permissions.
#
# Debug only. Release is left signing ad-hoc so CI is unaffected.
require 'xcodeproj'

CERT_NAME = 'Brim Local Dev'

# Sign by certificate hash, not by name: the certificate is self-signed and
# therefore untrusted, so Xcode will not resolve it by name. codesign accepts
# the hash, which is all TCC needs — the designated requirement becomes
# `identifier "<bundle id>" and certificate leaf = H"<hash>"`, identical on
# every rebuild, so permissions granted once persist.
keychain = File.expand_path('~/Library/Keychains/login.keychain-db')
hash_line = `security find-certificate -c "#{CERT_NAME}" -Z "#{keychain}" 2>/dev/null`
             .lines.find { |l| l.include?('SHA-1 hash:') }
abort "Certificate '#{CERT_NAME}' not found. Run scripts/setup_dev_signing.sh first." unless hash_line
IDENTITY = hash_line.split.last

project = Xcodeproj::Project.open('Brim.xcodeproj')
target = project.targets.find { |t| t.name == 'brim' }
abort 'target "brim" not found' unless target

target.build_configurations.each do |config|
  if config.name == 'Debug'
    config.build_settings['CODE_SIGN_IDENTITY'] = IDENTITY
    config.build_settings['CODE_SIGN_STYLE'] = 'Manual'

    # Hardened runtime must stay OFF for Debug. It enforces library
    # validation, which requires every loaded library to share the main
    # binary's Team ID. A self-signed certificate has no Team ID while
    # Xcode's debug dylib is signed ad-hoc, so the loader refuses to map
    # brim.debug.dylib and the app dies at launch with
    # "different Team IDs". Hardened runtime belongs in Release.
    config.build_settings['ENABLE_HARDENED_RUNTIME'] = 'NO'
    config.build_settings.delete('OTHER_CODE_SIGN_FLAGS')
  else
    # Distribution keeps the hardened runtime and ad-hoc/CI signing.
    config.build_settings['ENABLE_HARDENED_RUNTIME'] = 'YES'
  end
end

project.save
puts "Debug signs as #{CERT_NAME} (#{IDENTITY}), hardened runtime off."
puts 'Release unchanged: ad-hoc signing, hardened runtime on.'
