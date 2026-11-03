# infra/

The CDK app that used to live here moved to `~/dev/thoughtreps-aws` and
deploys into the prod account (038635648573) through its pipeline. The legacy
stacks in the shared account were deleted on 2026-11-02. What's left:

- `lib/mail/inbox.ts` and `lib/export-link/schemas.ts`, exported as
  `@thoughtreps/infra/mail/inbox` and `@thoughtreps/infra/export-link/schemas`
  for `mail-web/` and `../transfer-web/`. They are byte-for-byte copies of the
  same paths in `~/dev/thoughtreps-aws/infra/lib/`, which is the source of
  truth: change them there first, then copy them here unchanged.
- `mail-web/`, the inbox UI at mail.thoughtreps.com (Vite + React), deployed
  by `../scripts/deploy-mail-web.sh` from the prod Mail stack's outputs.

Infrastructure changes (stacks, Lambdas, DNS, mail rules) go in
`~/dev/thoughtreps-aws`, never here.
