#!/bin/bash
set -euo pipefail
: "${DEVELOPER_DIR:?Set the Xcode developer directory}"
: "${KEYCHAIN_PROFILE:?Set a matching macOS provisioning profile path}"
: "${KEYCHAIN_SIGN_IDENTITY:?Set the existing signing certificate SHA-1}"
export DEVELOPER_DIR
project_root="$(cd "$(dirname "$0")/.." && pwd)"
probe_root="$(mktemp -d "${TMPDIR:-/tmp}/marketdecision-keychain.XXXXXX")"
trap 'rm -rf "$probe_root"' EXIT
security cms -D -i "$KEYCHAIN_PROFILE" > "$probe_root/profile.plist"
python3 - "$probe_root" "$KEYCHAIN_SIGN_IDENTITY" "$project_root/Scripts" <<'PY'
import datetime, hashlib, pathlib, plistlib, sys
sys.path.insert(0, sys.argv[3])
from profile_time import require_unexpired
root=pathlib.Path(sys.argv[1]); profile=plistlib.loads((root/'profile.plist').read_bytes())
assert 'OSX' in profile.get('Platform', []), 'A macOS profile is required; iOS profiles cannot authorize this host'
require_unexpired(profile['ExpirationDate'])
assert sys.argv[2].upper() in [hashlib.sha1(c).hexdigest().upper() for c in profile['DeveloperCertificates']], 'Certificate is not authorized by profile'
e=profile['Entitlements']; app=e.get('com.apple.application-identifier','')
assert '.' in app, 'Profile lacks macOS application identity'
# Fixed probe identity: never borrow the identity of another application.
bundle='local.marketdecision.keychainprobe'
prefix=app.split('.',1)[0]; identity=prefix+'.'+bundle
assert app == identity or (app.endswith('.*') and identity.startswith(app[:-1])), 'Profile does not authorize probe bundle ID'
group_patterns=e.get('keychain-access-groups',[])
assert any(g==identity or (g.endswith('.*') and identity.startswith(g[:-1])) for g in group_patterns), 'Profile lacks matching keychain access group'
entitlements={'com.apple.security.app-sandbox':True,'com.apple.application-identifier':identity,'com.apple.developer.team-identifier':e['com.apple.developer.team-identifier'],'keychain-access-groups':[identity]}
(root/'entitlements.plist').write_bytes(plistlib.dumps(entitlements))
contents=root/'KeychainProbe.app/Contents'; (contents/'MacOS').mkdir(parents=True)
(contents/'Info.plist').write_bytes(plistlib.dumps({'CFBundleIdentifier':bundle,'CFBundleExecutable':'KeychainProbe','CFBundlePackageType':'APPL','CFBundleVersion':'1'}))
PY
probe_app="$probe_root/KeychainProbe.app"
cp "$KEYCHAIN_PROFILE" "$probe_app/Contents/embedded.provisionprofile"
xcrun swiftc -swift-version 6 -parse-as-library "$project_root/Sources/Security/CredentialStore.swift" "$project_root/Tests/KeychainHost/KeychainProbe.swift" -o "$probe_app/Contents/MacOS/KeychainProbe"
codesign --force --sign "$KEYCHAIN_SIGN_IDENTITY" --entitlements "$probe_root/entitlements.plist" --timestamp=none "$probe_app"
codesign --verify --strict "$probe_app"
"$probe_app/Contents/MacOS/KeychainProbe"
