# Script for populating the database. You can run it as:
#
#     mix run priv/repo/seeds.exs
#
# It is idempotent: existing settings, users, and agents are left untouched.
# A failure prints `seeder stopped: <reason>` and exits non-zero.

Canopy.Seeds.run_cli!()
