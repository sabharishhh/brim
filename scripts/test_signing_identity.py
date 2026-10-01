import subprocess
import unittest
from unittest.mock import patch

from signing_identity import select_identity


class SigningIdentityTests(unittest.TestCase):
    fingerprint = "A" * 40
    name = "Apple Development: developer@example.com (RC2W7RT2JJ)"

    def outputs(self, team="9LY29YLFG2", digest=None):
        digest = digest or self.fingerprint
        values = [
            f'1) {self.fingerprint} "{self.name}"',
            "-----BEGIN CERTIFICATE-----\nfixture\n-----END CERTIFICATE-----",
            f"subject=CN={self.name},OU={team},O=Developer,C=US\nSHA1 Fingerprint={digest}\n",
        ]
        return [subprocess.CompletedProcess([], 0, value, "") for value in values]

    @patch("signing_identity.subprocess.run")
    def test_display_name_identifier_does_not_replace_the_certificate_team(self, run):
        run.side_effect = self.outputs()
        self.assertEqual(select_identity("9LY29YLFG2"), self.fingerprint)

    @patch("signing_identity.subprocess.run")
    def test_another_team_is_refused_even_with_a_matching_display_name(self, run):
        run.side_effect = self.outputs(team="ANOTHERTEAM")
        with self.assertRaisesRegex(ValueError, "No valid Apple signing identity"):
            select_identity("9LY29YLFG2")

    @patch("signing_identity.subprocess.run")
    def test_certificate_must_match_the_valid_private_key_identity(self, run):
        run.side_effect = self.outputs(digest="B" * 40)
        with self.assertRaises(ValueError):
            select_identity("9LY29YLFG2")

    @patch("signing_identity.subprocess.run")
    def test_requested_identity_cannot_fall_back_to_another(self, run):
        run.side_effect = self.outputs()[:1]
        with self.assertRaises(ValueError):
            select_identity("9LY29YLFG2", "B" * 40)
        self.assertEqual(run.call_count, 1)


if __name__ == "__main__":
    unittest.main()
