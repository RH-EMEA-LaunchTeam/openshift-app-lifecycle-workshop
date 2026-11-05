# Workshop Conventions

## Repository Purpose

Antora courseware for a workshop series that takes one reference application
(`notes-app`, in `app/`) through its full operational lifecycle on OpenShift:
onboarding-ready packaging, build pipelines, GitOps deployment, observability,
backup and restore, monthly base-image patching, security operations, fleet
governance and an end-to-end capstone. Each session is a 60-90 minute live demo
on a throwaway Demo Platform cluster followed by two days of hands-on access.

## Structure

- `documentation/` contains all AsciiDoc courseware content (Antora component)
- `documentation/modules/ROOT/pages/` contains the course pages in `.adoc` format
- Page and step directory prefixes: first digit = session, second digit = step
  (`13-config-and-secrets` = Session 1, Step 3). `00-setup` is shared.
- `app/` holds the reference application and both Containerfiles; reused by all sessions
- YAML manifests live in the root step directories (`11-legacy-app/`, `12-image-hygiene/`, ...)
- `16-admission-checklist/audit-namespace.sh` audits a namespace against the checklist
- Sessions 2-9 (`20-` to `90-` pages) are planned outlines; expand them into
  `2N-*.adoc` step pages and `2N-*/` manifest directories when built
- Steps are progressive: each builds on the previous one
- `t/` holds private working notes: gitignored, never publish, never reference

## AsciiDoc Formatting

- Every numbered step must have a *What* and *Why* pair in bold
- Every step must have a collapsible verification block
- Use `[.console-input]` before source blocks for commands
- Use `[.console-output]` before source blocks showing expected output
- Reference YAML manifests by file path in `oc apply -f` commands
- Do not use em dashes. Use regular dashes (`-`) instead
- Use `'''` for horizontal rules between steps
- Cross-reference other pages with `xref:page.adoc[Label]`
- External links use `link:URL[Label]`
- Use `NOTE:`, `TIP:`, `IMPORTANT:`, `WARNING:` admonitions
- All doc links must point to `docs.redhat.com` or `docs.openshift.com`
- Use attributes from `_attributes.adoc` for version numbers

## CLI Conventions

- Every `oc` command must include an explicit `--context lab` (`{lab-context}`) flag
- Every namespaced command uses `-n "$NS"`; manifests do not hard-code a namespace
- Never use `oc login` inside step pages (only in `00-setup.adoc` / `myenv.sh`)
- YAML files with `${VARIABLE}` placeholders use `envsubst`
- All workshop variables are exported once in `00-setup.adoc`
- Secrets are created with `oc create secret`; never commit Secret manifests

## Content Rules

- Never include customer names, real people's names, email addresses or customer
  infrastructure details (the repo owner handle in URLs, third-party library names
  and fake example usernames are fine)
- All content must be in English
- Prefer `registry.access.redhat.com` or `registry.redhat.io` images
  (the only Docker Hub image is the intentional legacy base in `app/Containerfile.legacy`)
- Use Red Hat / OpenShift-native components when they cover the use case
- Mention Red Hat products because they fit the solution, not to promote them

## YAML Conventions

- Every YAML file starts with a comment block: filename and purpose
- Use `app.kubernetes.io/part-of: notes-app` label consistently
- Include resource requests and limits on Deployments (except where a step
  intentionally omits them to demonstrate the problem)
- Include readiness and liveness probes where applicable
