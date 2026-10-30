# vatio-sdk

Signs and verifies the one credential a Vatio workspace authenticates its users
with: a JWT your application signed with its own private key.

Vatio holds only the public half, so it can check a token and never mint one.
That is the property that makes it reasonable for a platform to be verifying
identity at all — and it is also why everything dangerous about the arrangement
sits on *your* side of the line. This gem is that side, done once.

Building your app with Claude Code, Cursor or Codex? Start with
`npx @vatio-ai/skills` and `/vatio-init` in its project. When the agent needs to
know who your users are and your backend is Rails, your coding agent can set
this gem up for it. See [vatio.ai](https://vatio.ai).

```ruby
gem "vatio-sdk", "~> 0.7"
```

On [RubyGems](https://rubygems.org/gems/vatio-sdk) from 0.6.0. Until then it was
called `vatio-identity` and installed from git; a Gemfile that still says
`gem "vatio-identity", git: "https://github.com/vatio-ai/ruby"` keeps working
and installs this, so switch when you next touch it. The code, the requires and the `Vatio::Identity` and
`Vatio::Server` modules did not change.

## Setup

The keypair comes from the CLI, not from here — `vatio auth --new-key` writes
`identity.pub` and `identity.pem` in the workspace, gitignores the private half
and prints the `vatio.yml` to go with it. There is deliberately no rake task
that does the same thing differently.

```ruby
# config/initializers/vatio.rb
Vatio::Identity.configure do |c|
  c.audience    = "acme"                               # your workspace slug
  c.private_key = ENV.fetch("VATIO_IDENTITY_PRIVATE_KEY")
end
```

`algorithm` is inferred from the key — the curve fixes it for EC, RS256 for RSA
— and has to match `auth.algorithm` in `vatio.yml`.

## The web

```erb
<%= raw Vatio::Identity.widget_tag(
      workspace: "acme",
      token: "vatpub_...",
      subject: current_user&.id,
      claims: { name: current_user&.name, email: current_user&.email }) %>
```

No `subject`, no visitor token, and the agent answers with its public tools —
which is what a signed-out visitor should get.

Add `metadata` to `claims` and whoever answers in the inbox sees a link to the
person in your admin, plus badges:

```ruby
claims: {
  name: current_user.name,
  metadata: {
    profile: admin_user_url(current_user),
    badges: { plan: { value: current_user.plan, tone: "green" }, country: current_user.country }
  }
}
```

See [Enrich the inbox](https://vatio.ai/docs/authentication/#enrich-the-inbox).

**Watch the cache.** Rails renders this per request, so it is safe by default.
The moment it lands in a page cache, a CDN or `caches_action`, you are serving
one customer's identity to the next visitor. If anything caches the page,
render it without a token and call `window.VatioWidget.identify(token)` from an
uncached endpoint instead.

## WhatsApp and Instagram

A WhatsApp or Instagram chat has no page to put a token on, so when a private
tool needs one Vatio sends the contact a "Sign in" button. It opens
`auth.sign_in_url` from `vatio.yml` with a `code`; sign them in the way your
site already does, then send them back:

```ruby
# auth:
#   public_key: identity.pub
#   sign_in_url: https://acme.com/vatio/sign-in
class VatioSignInsController < ApplicationController
  before_action :authenticate_user!   # your own login

  def show
    # Back from a Turbo login form: fetch cannot follow a redirect to vatio.ai.
    if request.headers["X-Turbo-Request-Id"]
      return render html: helpers.tag.meta(name: "turbo-visit-control", content: "reload")
    end

    redirect_to Vatio::Identity.sign_in_redirect_url(
      code: params[:code],
      subject: current_user.id,
      claims: { name: current_user.name, phone_number: current_user.phone }
    ), allow_other_host: true
  end
end
```

The token lasts a week by default (`expires_in:` to change it); when it runs
out the button goes out again. A `phone_number` claim that matches the WhatsApp
number skips the "is this yours?" confirmation; on Instagram it is always asked.

Keep the Turbo lines if your login form uses Turbo: after signing in, the form's
`fetch` follows the redirect back here and cannot follow the next one to
vatio.ai, so the login page would just sit there. The reload makes it a real
page load.

## Your own API, behind a private tool

```ruby
class Api::BookingsController < ApplicationController
  include Vatio::Identity::Authentication
  before_action :authenticate_vatio!

  def index
    render json: Booking.where(user_id: vatio_subject)
  end
end
```

Scope by `vatio_subject` and nothing else. Vatio already refuses to deploy a
private tool that takes `user_id` as a parameter — the model fills parameters
and can be talked into filling that one with someone else's id — and the same
reasoning applies one layer down: an endpoint that accepts an id has to
remember to scope it every time, forever; one that reads the token cannot
forget.

## Several workspaces

`configure` sets one workspace for the whole app. An app that serves several —
each customer with their own Vatio workspace and key — builds a `Config` per
workspace instead and passes it as `config:`:

```ruby
config = Vatio::Identity::Config.new(audience: tenant.vatio_slug, public_key: tenant.vatio_public_key)

Vatio::Identity.verify(token, config: config)
```

`token_for`, `widget_tag` and `sign_in_redirect_url` take it too; those sign,
so that config needs `private_key:`. Behind a private tool, the controller
says which workspace the request is for, and `nil` for a tenant that has not
connected Vatio answers 401:

```ruby
class Api::BookingsController < ApplicationController
  include Vatio::Identity::Authentication
  before_action :authenticate_vatio!

  private

  def vatio_identity_config
    return if current_tenant.vatio_public_key.blank?

    Vatio::Identity::Config.new(audience: current_tenant.vatio_slug, public_key: current_tenant.vatio_public_key)
  end
end
```

Pick the tenant from the request — the host, the path — and never from the
token's own `aud`: the token is what is being checked.

A server client for another workspace takes its identity config the same way,
so a `subject:` is signed with that workspace's key:

```ruby
Vatio::Server::Client.new(server_key: tenant.vatio_server_key, workspace: tenant.vatio_slug,
  identity: Vatio::Identity::Config.new(audience: tenant.vatio_slug, private_key: tenant.vatio_private_key))
```

`SendMessageJob` always uses the global configuration.

## Server API (messages)

Everything above runs without a network call. This part is the opposite: a
client for the server API, which has the agent write to someone first on
WhatsApp — an order that shipped, an appointment tomorrow, a quote that is
ready — and the receiver for the webhooks that say how it went. It is a
separate require, so an app that only signs tokens never loads it:

```ruby
# config/initializers/vatio.rb
require "vatio/server"

Vatio::Server.configure do |c|
  c.server_key     = ENV.fetch("VATIO_SERVER_KEY")       # vsk_..., from `vatio keys create secret`
  c.workspace      = "acme"                               # defaults to Vatio::Identity's audience
  c.webhook_secret = ENV["VATIO_WEBHOOK_SECRET"]          # whsec_..., for the receiver below
end
```

A secret key belongs to one workspace and one environment, and a preview key
can only write, from Vatio's shared WhatsApp number, to someone on the
workspace's team with their WhatsApp verified, or to a customer phone added in
the inbox's Try the agent panel (WhatsApp). Keep it on your server: it can
message your customers. Net::HTTP does the talking
(`base_url`, `open_timeout` and `read_timeout` are there if you need them);
there is no other dependency.

### Sending

```ruby
message = Vatio::Server.send_message(
  to: "+56912345678",
  brief: "Order #1042 shipped today with Starken, tracking 99812. Offer to send the tracking link.",
  external_ref: "order-1042-shipped"
)
message.queued?   # => true -- recorded and on its way
message.id        # => 81
```

What goes out depends on WhatsApp's 24-hour window, which Vatio checks for
you:

- **`brief:`** — the agent writes the message, and on every later turn it is
  shown why it wrote, so "yes, send it" gets an answer that knows what "it"
  is. Write it the way you would brief a colleague: the agent uses no facts
  beyond the brief and its tools.
- **`text:`** — your own words, sent as is.
- **`template:`** — `{ name:, language:, params: [] }`, used only when the
  window is closed, because then WhatsApp delivers nothing else. Send it
  along with the brief to always reach the person. `Vatio::Server.templates`
  lists what the number can send, with each body's parameter count:

  ```ruby
  shipped = Vatio::Server.templates.find { |t| t.name == "order_shipped" }
  Vatio::Server.send_message(to: phone, brief: brief, template: shipped.with_params("Ana", "#1042"))
  ```

  A URL button whose link ends in `{{1}}` takes its value per message, by
  the button's position (`template.buttons` lists them):

  ```ruby
  template: offer.with_params("Ana").merge(buttons: [{ index: 0, params: [offer.code] }])
  ```

  Anything else a template takes (a media or text header, named
  parameters, a coupon code) goes as Meta's own send components, as each
  template's `example` shows:

  ```ruby
  template: { name: "ati_offer", language: "es", components: [
    { type: "header", parameters: [{ type: "image", image: { link: photo_url } }] },
    { type: "body", parameters: [{ type: "text", parameter_name: "name", text: "Ana" }] }
  ] }
  ```

The response only says it is queued: the agent's turn and Meta's delivery
both happen after it. `Vatio::Server.message_status(id)` reads it back,
with `content` (what reached the phone) once it is sent, and
`Vatio::Server.messages(external_ref:, status:, limit:, before:)` lists
them, newest first — or, better, the webhook tells you.

**Who it is.** If the person is one of your users, pass `subject:` (and
`claims:`, as for the widget) and the message carries an identity signed
with your key, so a private tool can run when they answer:

```ruby
Vatio::Server.send_message(to: user.phone, brief: brief, external_ref: "invoice-#{invoice.id}-due",
  subject: user.id, claims: { name: user.name })
```

The token's `exp` is `identity_ttl` from now, 48 hours by default, and it has
to cover how long the person may take to answer: past it, they are answered
as a stranger. Pass a longer one for a message people sit on. Or sign it
yourself and pass `identity:`.

### Idempotency

A request that timed out may still have gone through, so a retry has to be
safe. It is when it carries an idempotency key: the same key with the same
request answers with the message the first one made (`replayed?` is true)
and sends nothing. `idempotency_key:` defaults to `external_ref:`, so give
each *message* its own ref — `"order-1042-shipped"`, not `"order-1042"` —
or pass a key explicitly. The same key with a different request is a
`Conflict`, not a second message.

If you retry a call with `subject:` yourself, sign once with
`Vatio::Server.identity_for(subject:, claims:)` and pass that as `identity:`:
a token signed again is a different request to that check.

### Errors

Every refusal raises a `Vatio::Server::Error` with `code`, `message`,
`status`, `details` and `request_id` (quote it when you ask us about one).
The subclasses are the decisions you actually make:

```ruby
begin
  Vatio::Server.send_message(to: phone, brief: brief, external_ref: ref)
rescue Vatio::Server::OutsideWindow => e
  # Has not written in 24 hours and no template was sent. Only you know
  # whether a template is the right thing instead. e.last_inbound_at
rescue Vatio::Server::OptedOut, Vatio::Server::HumanAnswering
  # They asked not to be written to, or a person has the conversation
  # (human_takeover, handoff_pending). Leave it.
rescue Vatio::Server::RateLimited, Vatio::Server::Unavailable => e
  # e.retryable? is true for these two only. Retry with the same key.
end
```

| Class | When |
|---|---|
| `OutsideWindow` | `outside_window`, with `last_inbound_at` |
| `OptedOut` | `opted_out` |
| `HumanAnswering` | `human_takeover`, `handoff_pending` |
| `TemplateError` | `template_not_found` (often created in Meta a minute ago: Vatio is syncing, retry shortly), `template_not_approved`, `template_params`, `template_buttons`, `template_components`, `template_required` |
| `InvalidRequest` | Any other 422: `invalid_recipient`, `content_required`, `invalid_identity`, `not_a_test_phone`… |
| `Unauthorized` | 401 / 403: the key is wrong, revoked, or another workspace's |
| `Conflict` | Any other 409: `idempotency_conflict` (`details["message_id"]`), `identity_conflict`, `whatsapp_not_connected`, `whatsapp_paused`, `whatsapp_number_unhealthy` (Meta refuses every send from the number; `details["issue"]` says why and the fix) |
| `NotFound` | `message_status` with an id this key cannot see |
| `RateLimited` | 429, more than 60 a minute on one key |
| `Unavailable` | 5xx, timeouts, refused connections |

A missing `server_key` or `workspace` is a `Vatio::Server::ConfigurationError`,
not one of these: it is your bug, not Vatio's answer.

### ActiveJob

Where ActiveJob is loaded, `Vatio::Server::SendMessageJob` takes the same
keywords:

```ruby
Vatio::Server::SendMessageJob.perform_later(to: order.phone, brief: brief,
  external_ref: "order-#{order.id}-shipped", subject: order.user_id)
```

It retries `RateLimited` and `Unavailable` with backoff, ten attempts over
about four hours, and never the rest — a closed window is the same answer
on the tenth try — which it logs and discards. To act on one, subclass and
`discard_on` it; the later declaration wins:

```ruby
class ShippedJob < Vatio::Server::SendMessageJob
  discard_on(Vatio::Server::OutsideWindow) { |job, error| ShippedMailer.notify(job.arguments.first[:to]).deliver_later }
end
```

Pass an `external_ref` or `idempotency_key` so a retry is a replay rather than
a second message; without one the job makes a key when it is enqueued. An
identity for `subject:` is signed at enqueue as well, once, for the same
reason — which means it waits in your queue, and its `exp` counts from then.

### Webhooks

Vatio POSTs `message.sent`, `message.failed`, `message.delivered`,
`message.read`, `message.delivery_failed` and `message.replied` to your
endpoint, signed with its `whsec_` secret. `data["message"]` is the message
as `message_status` returns it, and `message.replied` adds `data["reply"]`
(`chat_message_id`, `content`, `at`). `feedback.submitted` is a visitor's
rating of a conversation, with `data["feedback"]`, `data["chat"]` and
`data["contact"]` ([payload](https://vatio.ai/docs/api/webhooks#ratings)):

```ruby
# config/routes.rb
post "/webhooks/vatio", to: "vatio_webhooks#create"

class VatioWebhooksController < ActionController::API
  include Vatio::Server::WebhookReceiver

  on_vatio_event "message.replied" do |event|
    next if ProcessedEvent.exists?(event_id: event["id"])

    message = Vatio::Server::Message.from(event["data"]["message"])
    Order.find_by(ref: message.external_ref)&.update!(customer_replied_at: message.replied_at)
    ProcessedEvent.create!(event_id: event["id"])
  end
end
```

The receiver checks `Vatio-Signature` against the raw body and refuses a
delivery more than five minutes old, so a captured one cannot be replayed;
it answers 400 to anything that does not verify and 200 otherwise. Define
`vatio_webhook_secret` in the controller to read the secret from elsewhere,
or override `handle_vatio_event(event)` to see every event. Outside Rails,
`Vatio::Server::Webhook.verify!(payload:, signature:, secret:)` returns the
parsed event or raises `Webhook::InvalidSignature`.

**Delivery is at least once.** A delivery your server took too long to
answer is sent again, with the same `event["id"]`: dedupe on it. A handler
that raises answers 500 and the delivery is retried later, which is what you
want when your database was down — and why a handler should be safe to run
twice.

### Testing

```ruby
require "vatio/server/testing"

setup    { Vatio::Server::Testing.fake! }
teardown { Vatio::Server::Testing.real! }

test "shipping tells the customer" do
  Order.ship!(order)
  sent = Vatio::Server::Testing.messages.last
  assert_equal "order-#{order.id}-shipped", sent.external_ref
  assert_equal order.user_id.to_s, sent.subject
end

test "a closed window falls back to email" do
  Vatio::Server::Testing.fail_next!(:outside_window)
  assert_emails(1) { Order.ship!(order) }
end
```

`fake!` swaps the HTTP transport for an in-memory one — no network, no key
needed — that answers as the API does: a queued message, a replay for a key
it has seen, `Conflict` for one reused with a different request. The answers
go through the same parsing and error mapping as real ones, so what your code
rescues in a test is what it rescues in production. `fail_next!` takes any
refusal code (or `:timeout`); `window_open = false` makes a message without
a template raise `OutsideWindow`; `templates =` sets what `templates`
returns; `webhook("message.replied", message: {...})` builds a signed
request for testing your receiver. With RSpec loaded:

```ruby
expect { Order.ship!(order) }.to have_sent_message(to: order.phone, brief: a_string_including("#1042"))
```

See [Messages](https://vatio.ai/docs/api/messages) for the API itself.

## Async tools

A tool declared `async:` in its `tools/*.yml` is one whose work takes longer
than a reply can wait: Vatio calls your endpoint with a job, your endpoint
answers 202 at once, and your worker posts the result when it has it. The
agent tells the person it is on it, knows the job is running on every turn,
and gives them the result in the same conversation, on any channel
([Long-running tools](https://vatio.ai/docs/guides/ai-agent-long-running-tools)).
It is part of `require "vatio/server"`, and needs no server key: the job's
callback URL is signed and names that one job.

```ruby
class Vatio::MatchesController < ApplicationController
  include Vatio::Server::AsyncTool
  before_action :check_tool_key            # the tool's own Authorization, as for any tool

  def create
    MatchTherapistsJob.perform_later(vatio_job, reason: params[:reason], area: params[:area])
    accept_vatio_job(message: "Finding matches; this usually takes about two minutes.")
  end
end

class MatchTherapistsJob < ApplicationJob
  def perform(vatio_job, reason:, area:)
    vatio_job.run do |job|
      job.progress("Reviewing 12 therapists in your area", notify: true)
      therapists = Therapists.match(reason, area)
      { result: "ok", message: "#{therapists.size} found", data: { therapists: therapists.map(&:to_h) } }
    end
  end
end
```

- **`vatio_job`** reads the job from the request (`X-Vatio-Job-Id`,
  `X-Vatio-Callback-Url`), or is nil when the call carries none: answer as any
  tool then. A callback URL on any host but Vatio's raises
  `InvalidRequest`, so a forged request cannot send your worker's results
  elsewhere. **`accept_vatio_job`** answers 202; its `message` reaches the
  agent.
- **The job is an ActiveJob argument** as it is. For another queue, store
  `job.to_h` and rebuild it with `Vatio::Server::Job.from(hash)`. Your queue
  stores the callback URL: treat it as a secret (`inspect` leaves it out).
- **`run`** posts what the block returns as the result: the body your
  endpoint would have answered had it been fast, read through the tool's
  `respond:`. If the block raises, the job is reported failed, so the
  person hears now rather than at the timeout, and the error is raised on
  for your queue. If the job is over while it runs (it timed out, or the
  person called it off) it stops and returns nil.
- **By hand:** `progress(text, notify:)`, `complete(message:, data:)`,
  `failed(message, error_key:)` and `respond(hash)`. Each returns the job's
  `status` and whether the result was a `duplicate?`. Vatio unreachable or
  rate limiting is retried three times in the call, over about 20 seconds,
  rather than by your queue, which would redo the work. `JobClosed` means
  the job is over: stop.

In tests, `Vatio::Server::Testing.job` builds a job to pass to your code,
`job_headers(job)` the headers for a request test of the endpoint, and
`callbacks` is what your code posted:

```ruby
setup { Vatio::Server::Testing.fake! }

test "matches are reported" do
  MatchTherapistsJob.perform_now(Vatio::Server::Testing.job, reason: "anxiety", area: "Ñuñoa")
  result = Vatio::Server::Testing.callbacks.last
  assert result.result?
  assert_equal "ok", result.body["result"]
end
```

## What it does not do

Rotate keys, or cache tokens. Verification is repeated on every gate by
design, so there is no conclusion worth caching: a token cached as "valid"
has its `exp` checked exactly once.

`vatio/identity` never talks to Vatio: signing and verifying are local, and
nothing about the widget or your private tools makes a request from here.
`vatio/server` is the one part that does, only when you require it and call
it, and it does not retry on its own — a retry belongs to whoever knows
whether the message still makes sense, which is why `SendMessageJob` is where
the retries are.

## Issues

Bugs and questions go to [issues](https://github.com/vatio-ai/ruby/issues).
This repository is a read-only mirror of the gem as it ships inside Vatio, so
a pull request cannot be merged here: open an issue describing the change
instead.

MIT licensed.
