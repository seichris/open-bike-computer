from pathlib import Path
import subprocess
import re

head = '7615e418eb535789eb9103fa106650641421cc5f'
files = [
 'ios-app/BikeComputer/BikeComputer/Managers/RideDetectionSettingsStore.swift',
 'ios-app/BikeComputer/BikeComputer/Managers/RideAutomationCoordinator.swift',
 'ios-app/BikeComputerTests/WorkoutMirrorManagerTests.swift',
]
patch = subprocess.check_output(['git','diff',head+'^',head,'--',*files])
subprocess.run(['git','apply','-'], input=patch, check=True)
path = 'ios-app/BikeComputerTests/WorkoutContractTests.swift'
patch = subprocess.check_output(['git','diff',head+'^',head,'--',path], text=True)
parts = re.split(r'(?=^@@ )',patch,flags=re.M)
keep = [parts[0]]
for hunk in parts[1:]:
    if any(s in hunk for s in ['ControllableRecoveryPersistence', 'RideDetectionSettingsStore', 'savePendingDecision', 'decision-write-and-crash', 'decision-read-after-crash']):
        keep.append(hunk)
subprocess.run(['git','apply','--recount','-'], input=''.join(keep),text=True,check=True)

p = Path(files[2]); s = p.read_text()
needle = '        XCTAssertFalse(pendingWasDurableAtAcknowledgement)\n'
assert s.count(needle)==1
s = s.replace(needle, needle+'''        XCTAssertFalse(sentFrames.contains {
            $0.kind == .acknowledgement && $0.acknowledgedKind == .decision
                && $0.decisionSequence == decision.decisionSequence
        })
''')
p.write_text(s)

p = Path(path); s = p.read_text()
needle = '            afterCommit.loadPendingDecision() == nil, "committed state restores atomically")\n'
assert s.count(needle)==1
s = s.replace(needle,needle+'''
        let legacyName = "RideDecisionMigration.\\(UUID().uuidString)"
        let legacyDefaults = UserDefaults(suiteName: legacyName)!
        defer { legacyDefaults.removePersistentDomain(forName: legacyName) }
        legacyDefaults.set(["bike-a:7": 10], forKey: "rideDetection.decisionWatermarks.v1")
        legacyDefaults.set(try! PropertyListEncoder().encode(pendingStart),
            forKey: "rideDetection.pendingDecision.v1")
        let migrationPersistence = ControllableRecoveryPersistence()
        migrationPersistence.failsSave = true
        let blockedMigration = RideDetectionSettingsStore(
            defaults: legacyDefaults, decisionPersistence: migrationPersistence)
        expect(blockedMigration.loadPendingDecision() == nil,
            "failed migration must not replay the legacy outbox")
        expect(legacyDefaults.data(forKey: "rideDetection.pendingDecision.v1") != nil,
            "failed migration must retain legacy bytes for the next launch")
        migrationPersistence.failsSave = false
        let migrated = RideDetectionSettingsStore(
            defaults: legacyDefaults, decisionPersistence: migrationPersistence)
        expect(migrated.loadPendingDecision() == pendingStart &&
            migrated.loadDecisionWatermarks()["bike-a:7"] == 11,
            "migration must commit the pending identity and matching watermark together")
        expect(legacyDefaults.object(forKey: "rideDetection.pendingDecision.v1") == nil,
            "legacy bytes are removed only after the new journal commits")
        let corruptPersistence = ControllableRecoveryPersistence()
        corruptPersistence.data = Data("not a journal".utf8)
        let corruptStore = RideDetectionSettingsStore(
            defaults: legacyDefaults, decisionPersistence: corruptPersistence)
        do {
            try corruptStore.saveDecisionState(watermarks: [:], pending: nil)
            expect(false, "corrupt durable state must fail closed, not reset watermarks")
        } catch {}
        expect(corruptPersistence.data == Data("not a journal".utf8),
            "corrupt journal evidence must not be silently overwritten")
''')
p.write_text(s)

ledger = Path('docs/reviews/workout-lifecycle-fix-ledger.md')
ledger.parent.mkdir(parents=True,exist_ok=True)
s = subprocess.check_output(['git','show',head+':'+str(ledger)],text=True)
s += '''

## Reconciliation with current main — 2026-09-08

The original stack and validation above are historical. #388 is merged, and
its later implementation supersedes WRK-003 through WRK-005 here. This update
retains main's generated source-health contract, encoder failure cleanup,
continuous-stop reset and monotonic-uptime motion preparation. It also retains
#423's Watch shutdown/demand coordination byte-for-byte. None of the older
wall-clock motion helpers or alternative Watch queue implementation is replayed.

The remaining implementation delta is WRK-002 only: atomically persist the phone
decision watermark and pending/resolved operation before acknowledgement or
Watch control. Existing crash/relaunch and write-failure regressions are retained;
new checks cover legacy migration failure/retry, corrupt-journal fail-closed
behavior and absence of any decision acknowledgement after failed admission.
The current-main integration is deliberately limited to the two phone managers,
their two existing test files, and this ledger.

WRK-001 remains a separate, pre-existing unresolved HealthKit commit-unknown
recovery issue. This change does not retry uncertain HealthKit saves, mark them
saved/discarded without proof, add a stop-recovery action or enable production
automatic start. Merging this journal repair must not be described as resolving
all workout lifecycle findings.

Validation: generated-contract and whitespace checks passed during local
reconciliation. New and retained Apple-platform tests require the exact updated
head's macOS CI; they were not executed on the Linux editing host. Historical
native/host results above are not substituted for this integration's CI. No
physical devices, HealthKit writes, firmware builds, deployments or releases
were used by this reconciliation.
'''
ledger.write_text(s)
