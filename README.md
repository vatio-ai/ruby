# vatio-identity

Signs and verifies the one credential a Vatio workspace authenticates its users
with: a JWT your application signed with its own private key.

Vatio holds only the public half, so it can check a token and never mint one.
That is the property that makes it reasonable for a platform to be verifying
identity at all — and it is also why everything dangerous about the arrangement
sits on *your* side of the line. This gem is that side, done once.

```ruby
gem "vatio-identity", git: "https://github.com/vatio-ai/ruby", tag: "0.4.0"
```

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

See [Enrich the inbox](https://docs.vatio.ai/authentication/#enrich-the-inbox).

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

## What it does not do

Rotate keys, cache tokens, or talk to Vatio. Verification is repeated on every
gate by design, so there is no conclusion worth caching: a token cached as
"valid" has its `exp` checked exactly once.

## Issues

Bugs and questions go to [issues](https://github.com/vatio-ai/ruby/issues).
This repository is a read-only mirror of the gem as it ships inside Vatio, so
a pull request cannot be merged here: open an issue describing the change
instead.

MIT licensed.
