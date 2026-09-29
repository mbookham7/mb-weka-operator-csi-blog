# Cost controls (`cost-controls.tf`)

*[← back to the README](../README.md)*

This deployment runs at roughly **$20–25/hour**. Until `cost-controls.tf`
existed, the only thing enforcing that warning was the reader's attention
span — against a failure mode that *is* inattention.

`cost-controls.tf` gives you two guardrails. **Neither of them stops
anything** — the only real control is still `terraform destroy`:

- **An `ExpiresAt` tag on every resource**, computed from the actual creation
  time plus `ttl_hours` (default 8). Nothing reaps it. It exists so that
  "should this still be running?" is answerable at a glance, which in a shared
  account it otherwise is not:

  ```bash
  aws ec2 describe-instances \
    --filters "Name=tag:ManagedBy,Values=terraform" \
    --query "Reservations[].Instances[].[InstanceId,Tags[?Key=='ExpiresAt']|[0].Value]" \
    --output text
  ```

- **A daily budget alarm**, at 50% / 100% / 200% of `budget_limit_usd`
  (default 600 — roughly one full day at the defaults). Daily rather than
  monthly because the risk here is "it was left running", which a monthly
  budget hides for a fortnight and then resets.

  **It is only created if you set `budget_notification_emails`.** A budget
  with no subscribers is legal, shows in the console, and notifies nobody —
  that looks like protection while providing none, so this repo declines to
  create one. **Whether the alarm actually delivers is not something this repo
  has verified** — see below.

  Note the resolution: **AWS Budgets refreshes cost data roughly three times a
  day.** This is a backstop measured in hours, not a circuit breaker. By the
  time it fires you have already spent the money it is warning you about. It
  catches "left it up overnight", which is the realistic failure.

The budget is account-wide by default. Scoping it to the `Project` tag is a
one-line change (`budget_filter_by_project_tag`), but **a tag-filtered budget
can silently report $0**: cost allocation tags have to be activated by hand in
Billing → Cost allocation tags, activation takes up to 24 hours, and it is not
retroactive. A guardrail that quietly measures nothing is worse than none, so
the default is the scope that cannot fail that way.

## The TTL tag in detail

Every resource carries three tags, merged over `var.tags`:

| Tag | Value |
|---|---|
| `CreatedAt` | when `terraform apply` first created the deployment |
| `ExpiresAt` | `CreatedAt + ttl_hours` |
| `TTLHours` | the configured lifetime, for filtering |

`ExpiresAt` is computed with `time_static`, not `timestamp()`. That matters:
`timestamp()` re-evaluates on every plan, so every resource would show a tag
diff forever and `terraform plan` would never be clean. `time_static` records
the value once into state and holds it.

## The budget in detail

| Setting | Default | Why |
|---|---|---|
| `budget_limit_usd` | 600 | roughly one full day at the defaults |
| time unit | daily | the risk is "it was left running", which a monthly budget hides for a fortnight and then resets |
| thresholds | 50% / 100% / 200% actual | a forecast for a cluster you mean to destroy this afternoon is not actionable |
| scope | account-wide | see below |
| created? | only if `budget_notification_emails` is non-empty | a budget with no subscribers looks like protection and provides none |

## Two defaults chosen against the obvious option

**No emails, no budget.** A budget with no subscribers is legal and appears in
the console. It notifies nobody. That is worse than having none, because it
looks like a control — so the resource is not created at all unless you give
it somewhere to send the alert. Each address also gets an AWS confirmation
subscriber carries **no confirmation state at all**, and there is **no
confirmation step**.

Both parts were checked. The API returns only `Address` and
`SubscriptionType` from `describe-subscribers-for-notification`, and
`NotificationState: OK` on a notification means "threshold not breached", not
"subscription healthy". And across two budgets created and destroyed on
2026-09-29, each with three notifications and an email subscriber, **AWS sent
no confirmation email at all**. The subscribe-and-confirm handshake people
expect here is the **SNS** model; an `EMAIL` subscriber has nothing to accept.

So there is nothing to click and nothing to check.

**Delivery is confirmed.** A throwaway budget with a `$0.01` daily limit was
created against an account with $31.81 of spend that day. Its notification
went to `NotificationState: ALARM` **immediately on creation** — no waiting
for a refresh cycle — and the email arrived, from
`no-reply@budgets.alerts.amazonaws.com`. So a breached threshold does reach
an `EMAIL` subscriber, with no setup beyond listing the address.

Note what that also tells you about the real budget: during both deployment
runs it sat at `NotificationState: OK`, because $31.81 never approached
$600/day. **It was not silent, it was correctly quiet** — and the API will
tell you which:

```bash
aws budgets describe-notifications-for-budget \
  --account-id <acct> --budget-name weka-poc-daily-cost \
  --query "Notifications[].[Threshold,NotificationState]" --output text
```

If you want to re-prove delivery in your own account, the same trick works
and costs nothing — a budget with a limit your existing spend already
exceeds:

```bash
aws budgets create-budget --account-id <acct> --budget '{
  "BudgetName":"delivery-test","BudgetType":"COST","TimeUnit":"DAILY",
  "BudgetLimit":{"Amount":"0.01","Unit":"USD"}}' \
  --notifications-with-subscribers '[{
    "Notification":{"NotificationType":"ACTUAL","ComparisonOperator":"GREATER_THAN",
                    "Threshold":50,"ThresholdType":"PERCENTAGE"},
    "Subscribers":[{"SubscriptionType":"EMAIL","Address":"you@example.com"}]}]'
```

It alarms on creation if the spend is already past the threshold, so the mail
arrives in minutes. The "roughly three times a day" refresh applies to spend
*creeping* past a threshold, not to one already blown. Delete it afterwards —
it will mail you daily until you do.

**Account-wide, not tag-filtered.** A tag-filtered budget *can silently report
$0*: cost allocation tags must be activated by hand in Billing → Cost
allocation tags, activation takes up to 24 hours, and it is not retroactive.
A cost guardrail that quietly measures nothing is the worst possible outcome,
so the default is the scope that cannot fail that way.
`budget_filter_by_project_tag = true` opts in — activate the tag first, and
confirm in Cost Explorer that the filter returns non-zero before trusting it.

## One cost that is designed out rather than alarmed on

The client node group sits in the **same AZ as the WEKA backends**, so no
storage I/O crosses an availability zone boundary. Cross-AZ traffic is
charged in both directions, and on a parallel filesystem every read and
write would be on that path — for a sustained benchmark it can exceed the
NAT gateway charge that the cost table does itemise.

That one is not a tripwire, it is simply absent. See
[The client node group](node-group.md).

## What neither of them does

**Neither stops anything.** No Lambda reaps a tagged resource; no budget
throttles an account. They are a label and a tripwire. The only real control
is `terraform destroy` — see [Teardown](deployment.md#teardown).

## What happens to these on teardown

Both go with the stack, verified on the 2026-09-29 run:

- The **budget** is a Terraform resource, so `terraform destroy` removes it.
  Confirmed afterwards with `aws budgets describe-budgets`: nothing left. It
  does not linger as an orphan alarming on an account with no deployment.
- The **TTL tags** disappear with the resources they were on.

Which is worth saying plainly, because it means **neither survives to tell you
about a failed teardown.** If `destroy` leaves something behind — and the
first pass is *expected* to, see [Teardown](deployment.md#teardown) — the
budget that would have warned you about the resulting spend has usually
already been destroyed itself. Check the console after a teardown; do not wait
for an alert that can no longer fire.

## Permissions

`budgets:*` is needed to apply, but **only if you set
`budget_notification_emails`**. It is frequently absent from project-scoped
roles, because budgets are account-level. With no addresses set, no budget is
created and the permission is not needed.

---

*[← back to the README](../README.md)*
