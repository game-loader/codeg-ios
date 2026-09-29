#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build

# Select an installed, available iPhone on a compatible runtime.
xcrun simctl list --json > build/session-recovery-simulators.json
SIMULATOR_ID="$(python3 - <<'PY'
import json
from pathlib import Path
catalog = json.loads(Path('build/session-recovery-simulators.json').read_text())
runtimes = {
    r['identifier']: tuple(int(n) for n in r['version'].split('.'))
    for r in catalog['runtimes']
    if r.get('isAvailable') and '.iOS-' in r['identifier']
    and int(r['version'].split('.')[0]) >= 26
}
candidates = [
    (runtimes[runtime], d.get('state') == 'Booted', d['name'], d['udid'])
    for runtime, devices in catalog['devices'].items() if runtime in runtimes
    for d in devices if d.get('isAvailable')
    and ('iPhone' in d.get('deviceTypeIdentifier', '') or d['name'].startswith('iPhone'))
]
if not candidates:
    raise SystemExit('No available iPhone simulator with iOS >= 26; see build/session-recovery-simulators.json')
print(sorted(candidates, reverse=True)[0][-1])
PY
)"

# Verify the generated module setting behind @testable import Codeg.
xcodebuild -showBuildSettings -json \
  -project CodegiOS.xcodeproj -target CodegiOS -configuration Debug \
  -sdk iphonesimulator CODE_SIGNING_ALLOWED=NO > build/session-recovery-settings.json
python3 - <<'PY'
import json
from pathlib import Path
settings = json.loads(Path('build/session-recovery-settings.json').read_text())
app = next(s['buildSettings'] for s in settings if s['target'] == 'CodegiOS')
assert app['PRODUCT_MODULE_NAME'] == 'Codeg', app.get('PRODUCT_MODULE_NAME')
assert app['ENABLE_TESTABILITY'] == 'YES', 'Debug app must enable @testable import'
PY

xcrun simctl bootstatus "$SIMULATOR_ID" -b
xcodebuild test \
  -project CodegiOS.xcodeproj -scheme CodegiOSSessionRecovery -configuration Debug \
  -destination "platform=iOS Simulator,id=$SIMULATOR_ID" \
  -destination-timeout 120 \
  -derivedDataPath "$PWD/build/SimulatorDerivedData" \
  -resultBundlePath "$PWD/build/SessionRecovery-$(date +%s).xcresult" \
  -only-testing:CodegiOSTests/SessionForegroundRecoveryTests \
  -parallel-testing-enabled NO \
  -test-timeouts-enabled YES \
  -default-test-execution-time-allowance 30 \
  -maximum-test-execution-time-allowance 60 \
  -skipMacroValidation -skipPackagePluginValidation \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY= \
  DEVELOPMENT_TEAM= CODEG_DEVELOPMENT_TEAM= \
  2>&1 | tee build/session-recovery-tests.log
