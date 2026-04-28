# **ActionLibrary-Terraform-Control** | Contributing

| [Home](./README.md)
| [Changelog](./CHANGELOG.md)
| **Contributing**
| [Tech Doc](./techdoc.md)
| <!-- End Of Menu -->

---

Thanks for contributing. Keep changes focused and align docs with behavior.

## Scope

- Workflow changes must not break the plan/apply split — plan must always run before apply is gated.
- OIDC credential handling must not introduce static credential storage.
- Matrix generation logic must remain compatible with the account group file format.
- Update `CHANGELOG.md` under `logs/<version>.md` for any functional change.

## Pull Requests

- Target the `master` branch.
- One logical change per PR.
- Reference any related issue or ticket in the PR description.
