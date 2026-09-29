# ---------------------------------------------------------------------------
# Cost controls: a TTL tag and a budget alarm
# ---------------------------------------------------------------------------
# The README's loudest warning is that this deployment runs at roughly $20-25
# an hour, comfortably over $500 a day. Until this file existed, the only
# thing enforcing that warning was the reader's attention span -- and the
# failure mode it guards against is precisely inattention: you meant to run
# `terraform destroy` and then something else came up.
#
# WHAT THESE DO AND DO NOT DO
#
# Neither of these stops anything. They are a label and a tripwire:
#
#   the TTL tags    make an abandoned deployment identifiable. "Is this VPC
#                   still needed?" is unanswerable at a glance in a shared
#                   account; `ExpiresAt` in the past answers it.
#
#   the budget      tells you that you are already spending. AWS Budgets
#                   refreshes cost data roughly three times a day, so this is
#                   a BACKSTOP MEASURED IN HOURS, NOT A CIRCUIT BREAKER. By
#                   the time it fires you have spent the money it is warning
#                   you about. It catches "left it up overnight", which is the
#                   realistic failure, not "typo'd the instance count".
#
# The only real-time control is still `terraform destroy`. See the README
# teardown section.

# ---------------------------------------------------------------------------
# When was this deployment created?
# ---------------------------------------------------------------------------
# `timestamp()` is the obvious way to do this and it is a trap: it re-evaluates
# on every plan, so every resource shows a tag diff forever and `terraform
# plan` is never clean. `time_static` records the value ONCE, into state, and
# holds it until the resource is replaced -- which is exactly the semantics a
# creation timestamp needs.
#
# The `time` provider is already in .terraform.lock.hcl (a child module pulls
# it in), so declaring it in versions.tf adds a provider requirement but no
# new download and no lock file change.
resource "time_static" "deployed" {}

locals {
  ttl_expires_at = timeadd(time_static.deployed.rfc3339, "${var.ttl_hours}h")

  # --- The tags every resource in this configuration carries -------------
  #
  # Merged over var.tags rather than replacing it, and merged in THIS order so
  # a user who deliberately sets their own `ExpiresAt` in var.tags does not
  # have it silently overwritten... except they would. Deliberate: the whole
  # point is that the expiry is computed from the actual creation time, not
  # asserted by hand. If you need a different lifetime, change `ttl_hours`.
  #
  # Note what these are NOT: they are not enforced by anything in AWS. Nothing
  # reads `ExpiresAt` and terminates an instance. They exist so that a cleanup
  # script, a Config rule, or a human doing a Friday sweep can answer "should
  # this still exist?" without having to know what the deployment was for.
  #
  #   aws ec2 describe-instances \
  #     --filters "Name=tag:ManagedBy,Values=terraform" \
  #     --query "Reservations[].Instances[].[InstanceId,Tags[?Key=='ExpiresAt']|[0].Value]" \
  #     --output text
  common_tags = merge(var.tags, {
    CreatedAt = time_static.deployed.rfc3339
    ExpiresAt = local.ttl_expires_at
    TTLHours  = tostring(var.ttl_hours)
  })
}

# ---------------------------------------------------------------------------
# Budget alarm
# ---------------------------------------------------------------------------
# Created ONLY if you give it somewhere to send the alert. A budget with no
# subscribers is legal, appears in the console, and notifies nobody -- which
# is worse than no budget, because it looks like protection. So: no emails,
# no budget, and the README says so.
#
# DAILY rather than MONTHLY on purpose. The risk here is not "this project
# overspends its monthly allocation", it is "this was left running". A daily
# budget answers that question every day; a monthly one lets a forgotten
# cluster burn for a fortnight before crossing a monthly threshold, and then
# resets and gives it another fortnight.
#
# ACTUAL thresholds only, no FORECASTED. A forecast for a cluster you intend
# to destroy this afternoon is not information you can act on.
resource "aws_budgets_budget" "deployment" {
  count = length(var.budget_notification_emails) > 0 ? 1 : 0

  name         = "${local.name}-daily-cost"
  budget_type  = "COST"
  limit_amount = tostring(var.budget_limit_usd)
  limit_unit   = "USD"
  time_unit    = "DAILY"

  # --- Scope -------------------------------------------------------------
  #
  # Account-wide by default, and that default is chosen for a specific
  # reason: a tag-filtered budget CAN SILENTLY REPORT ZERO.
  #
  # Cost allocation tags have to be activated by hand in Billing -> Cost
  # allocation tags before AWS will break costs down by them, activation takes
  # up to 24 hours, and it is NOT retroactive -- spend incurred before you
  # activated the tag is invisible to the filter forever. A cost guardrail
  # that quietly measures $0 is the worst possible outcome, so the default is
  # the scope that cannot fail that way.
  #
  # Set `budget_filter_by_project_tag = true` if you are deploying into a
  # shared account where an account-wide budget would be drowned in unrelated
  # spend -- but activate the tag FIRST, and confirm in Cost Explorer that the
  # filter returns non-zero before you trust it.
  dynamic "cost_filter" {
    for_each = var.budget_filter_by_project_tag ? [1] : []
    content {
      name = "TagKeyValue"
      # AWS wants "user:<TagKey>$<TagValue>". That literal `$` sits right
      # before an interpolation, and HCL reads `$${` as an escaped `${`, so
      # this has to go through format() rather than string interpolation.
      values = [format("user:Project$%s", var.tags["Project"])]
    }
  }

  # 50%: you are running, and you know it. A useful "still up" nudge.
  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 50
    threshold_type             = "PERCENTAGE"
    notification_type          = "ACTUAL"
    subscriber_email_addresses = var.budget_notification_emails
  }

  # 100%: a full day's budget is gone. If you are not actively using it right
  # now, this is the one that should send you to `terraform destroy`.
  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 100
    threshold_type             = "PERCENTAGE"
    notification_type          = "ACTUAL"
    subscriber_email_addresses = var.budget_notification_emails
  }

  # 200%: something is wrong, or it has been up for days.
  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 200
    threshold_type             = "PERCENTAGE"
    notification_type          = "ACTUAL"
    subscriber_email_addresses = var.budget_notification_emails
  }

  lifecycle {
    precondition {
      condition     = !var.budget_filter_by_project_tag || try(var.tags["Project"], "") != ""
      error_message = "budget_filter_by_project_tag is true, but var.tags has no non-empty \"Project\" key to filter on. Either add one or leave the budget account-wide."
    }
  }
}
