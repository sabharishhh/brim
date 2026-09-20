# Switches Debug signing from the self-signed local certificate to an Apple
# Development certificate.
#
# Why bother, when the self-signed certificate signs perfectly well: TCC does
# not keep permissions for it. Grants given to an app signed by a self-signed
# certificate are revoked again shortly afterwards, even though the
# designated requirement is stable and the certificate is trusted for code
# signing. An Apple-anchored certificate is treated as a real identity and
# the grant persists.
#
# It is also needed for its own sake later. MutualAuthentication checks
# `certificate leaf[subject.OU]` for a Team ID, which only an Apple-issued
# certificate carries, and notarisation requires one.
#
# Prerequisite, which cannot be scripted: sign in to Xcode with an Apple ID
# (Xcode › Settings › Accounts › + › Apple ID). A free account is enough.
require 'xcodeproj'

identities = `security find-identity -v -p codesigning`.lines
apple_dev = identities.find { |l| l.include?('Apple Development') }

unless apple_dev
  abort <<~MISSING
    No "Apple Development" certificate found.

    Sign in first — Xcode › Settings › Accounts › + › Apple ID — then open the
    project, select the "brim" target, go to Signing & Capabilities and tick
    "Automatically manage signing", choosing your team. Xcode creates the
    certificate at that point. Then run this script again.

    Currently available:
    #{identities.join}
  MISSING
end

# "Apple Development: Name (TEAMID)" — the parenthesised value is the team.
team = apple_dev[/\(([A-Z0-9]{10})\)/, 1]
abort "Could not read a Team ID from: #{apple_dev.strip}" unless team

project = Xcodeproj::Project.open('Brim.xcodeproj')
target = project.targets.find { |t| t.name == 'brim' }
abort 'target "brim" not found' unless target

target.build_configurations.each do |config|
  next unless config.name == 'Debug'

  config.build_settings['CODE_SIGN_STYLE'] = 'Automatic'
  config.build_settings['CODE_SIGN_IDENTITY'] = 'Apple Development'
  config.build_settings['DEVELOPMENT_TEAM'] = team

  # Still off for Debug. Library validation would reject Xcode's ad-hoc
  # signed brim.debug.dylib against a Team-ID-bearing main binary, exactly
  # as it did with the self-signed certificate.
  config.build_settings['ENABLE_HARDENED_RUNTIME'] = 'NO'
end

project.save
puts "Debug now signs with Apple Development, team #{team}."
puts
puts 'Build once, then grant Full Disk Access to the new build. The bundle'
puts 'identity changes with the certificate, so this is a fresh grant — remove'
puts 'the old "Brim" entry from the list at the same time.'
