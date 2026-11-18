"""Compile the native patch's actual publication-age state without an Apple SDK."""

from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


PATCH = Path(__file__).resolve().parents[1] / "patches/godotrealitykit-hand-tracking.patch"


@unittest.skipUnless(shutil.which("c++"), "A C++ compiler is required for the native freshness regression")
class HandTrackingFreshnessTests(unittest.TestCase):
    def test_published_age_is_independent_of_pending_anchors(self):
        # This complete helper is added by the patch. Compile its exact production
        # definition, excluding platform-specific Metal/Swift bridge header imports.
        additions = "\n".join(line[1:] for line in PATCH.read_text().splitlines()
                              if line.startswith("+") and not line.startswith("+++"))
        begin = "// BEGIN standalone hand publication freshness"
        end = "// END standalone hand publication freshness"
        self.assertEqual(additions.count(begin), 1)
        self.assertEqual(additions.count(end), 1)
        helper = additions.split(begin, 1)[1].split(end, 1)[0]
        harness = r'''
#include <cstdlib>
#include <iostream>
#include <limits>

int main() {
    int checks = 0;
    auto check = [&](bool condition, const char *message) {
        ++checks;
        if (!condition) { std::cerr << message << '\n'; std::exit(1); }
    };
    GDRKHandTrackingFreshness left, right;
    check(!left.is_fresh(10.0), "No published hand exists before the first scene update");
    left.publish(9.8);
    right.publish(9.9);
    check(left.is_fresh(10.0), "Recently published left hand is valid");
    check(right.is_fresh(10.0), "Recently published right hand is valid");

    // ARKit delivers a new anchor while the render callback stalls. Its cache is
    // newer, but no call to publish() has delivered those joints to XRHandTracker.
    const double pending_anchor_timestamp = 10.02;
    const double now = 10.10;
    check(now - pending_anchor_timestamp < 0.25, "Pending anchor is fresh");
    check(!left.is_fresh(now), "New cached anchor cannot renew the old published pose");
    check(right.is_fresh(now), "Fresh right-hand publication survives left-hand expiry");
    check(!left.is_fresh(now), "Read-time guard remains false before the next watchdog tick");
    check(left.published_timestamp == 9.8, "Read-time freshness check is read-only");
    left.clear();
    check(!left.is_fresh(now), "Watchdog invalidation clears the published timestamp");
    check(right.is_fresh(now), "Invalidating one hand does not clear the other");
    left.publish(pending_anchor_timestamp);
    check(left.is_fresh(now), "Publishing the cached anchor permits recovery");

    left.publish(10.0);
    check(left.is_fresh(10.25), "Exact 250ms boundary is accepted");
    check(!left.is_fresh(10.250001), "Source age over 250ms is rejected immediately");
    check(!left.is_fresh(9.99), "A timestamp from the future is rejected");
    left.publish(-0.001);
    check(!left.is_fresh(0.0), "Negative source timestamp is rejected");
    left.publish(0.0);
    check(left.is_fresh(0.0), "Zero clock epoch is valid");
    left.publish(std::numeric_limits<double>::quiet_NaN());
    check(!left.is_fresh(10.0), "NaN source time is rejected");
    left.publish(std::numeric_limits<double>::infinity());
    check(!left.is_fresh(10.0), "Infinite source time is rejected");
    left.publish(10.0);
    check(!left.is_fresh(std::numeric_limits<double>::quiet_NaN()), "NaN clock is rejected");
    check(!left.is_fresh(std::numeric_limits<double>::infinity()), "Infinite clock is rejected");
    left.clear();
    right.clear();
    check(!left.is_fresh(10.0) && !right.is_fresh(10.0), "Lifecycle invalidation clears both hands");
    left.publish(20.0);
    check(left.is_fresh(20.0), "A new session can publish after lifecycle invalidation");
    check(!right.is_fresh(20.0), "A new left update does not revive the right hand");
    std::cout << "Native publication freshness: " << checks << " checks, 0 failures\n";
}
'''
        with tempfile.TemporaryDirectory(prefix="wisualizer-native-freshness-test-") as folder:
            root = Path(folder)
            source = root / "freshness.cpp"
            binary = root / "freshness"
            source.write_text("#include <cmath>\n" + helper + harness)
            compiled = subprocess.run([shutil.which("c++"), "-std=c++17", "-Wall", "-Wextra", "-Werror",
                                       str(source), "-o", str(binary)], capture_output=True, text=True)
            self.assertEqual(compiled.returncode, 0, compiled.stdout + compiled.stderr)
            result = subprocess.run([str(binary)], capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertIn("23 checks, 0 failures", result.stdout)
            print(result.stdout.strip())


if __name__ == "__main__":
    unittest.main()
