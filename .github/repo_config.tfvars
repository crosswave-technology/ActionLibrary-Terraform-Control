# name = <injected via github action>
description = "Composite GitHub Action for orchestrating Terraform init, plan, apply, and Checkov security scanning."
visibility  = "public"

pro_features_enabled = false

repository_settings = {
  archive_on_destroy   = true
  vulnerability_alerts = false

  has = {
    issues   = true
    projects = true
  }

  allow = {
    merge_commit  = true
    squash_merge  = true
    rebase_merge  = true
  }
}

collaborators = {
  pull     = ["team:*"]
  push     = []
  maintain = ["nexus"]
  admin    = []
}

features = {
  repository-control = {
    type                    = "gitflow"
    override_default_branch = "master"
  }
  nexus-control = {
    default_branch = "master"
  }
}

topics = ["github-actions", "composite-action", "terraform", "checkov", "ci-cd", "infrastructure-as-code"]

tag_protections = {
  version_tags = {
    pattern = "v*"
  }
}

environments = {
  "nexus-deploy" = {
    can_admins_bypass = true
  }
}

import_resources = {
  repository = "ActionLibrary-Terraform-Control"
}
