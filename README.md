# vatio-identity

Signs and verifies the one credential a Vatio workspace authenticates its users
with: a JWT your application signed with its own private key.

Vatio holds only the public half, so it can check a token and never mint one.
That is the property that makes it reasonable for a platform to be verifying
identity at all — and it is also why everything dangerous about the arrangement
sits on *your* side of the line. This gem is that side, done once.

```ruby
gem "vatio-identity", git: "https://github.com/vatio-ai/ruby", tag: "0.2.0"
```

## Setup

The keypair comes from the CLI, not from here — `vatio auth --new-key` writes
`identity.pub` and `identity.pem` in the workspace, gitignores the private half
and prints the `vatio.yml` to go with it. There is deliberately no rake task
that does the same thing differently.

The mint credential is just a random string, shared between Vatio and you:

```bash
openssl rand -hex 24
vatio secrets set VATIO_MINT_API_KEY <that value>   # so Vatio can send it
```

```ruby
# config/initializers/vatio.rb
Vatio::Identity.configure do |c|
  c.audience     = "acme"                               # your workspace slug
  c.private_key  = ENV.fetch("VATIO_IDENTITY_PRIVATE_KEY")
  c.mint_api_key = ENV.fetch("VATIO_MINT_API_KEY")
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

## WhatsApp, Instagram, and any channel with no session

There is no page to render a token onto, so Vatio asks you.

```ruby
# config/routes.rb
mount Vatio::Identity.mint { |channel:, phone_number: nil, instagram_id: nil, username: nil|
        user =
          case channel
          when "whatsapp" then User.find_by(phone_number: phone_number)
          when "instagram" then User.find_by(instagram_id: instagram_id)
          end
        next nil unless user
        { subject: user.id, claims: { name: user.name, email: user.email } }
      }, at: "/api/vatio/identity"
```

The block receives only the keywords it declares. One written for WhatsApp
alone, `|channel:, phone_number:|`, keeps working and answers every Instagram
request with the same 404 as a stranger. `**evidence` receives everything.

On Instagram, `instagram_id` is the IGSID: stable, and unique to this person
for your account. `username` is what Meta reports at the moment Vatio asks, and
is `nil` when Meta did not answer. Instagram usernames can be changed and then
taken by somebody else, so match on one only if you verified it belongs to the
user.

Return `nil` for someone you do not recognize: Vatio reads any non-2xx as "no
idea who this is", the visitor stays anonymous, and that is a normal outcome
rather than an error anyone needs to hear about.

### Checking that Vatio is the one asking

The shared secret stops anyone else from asking. It cannot prove who *is*
asking — whoever holds the string is indistinguishable from Vatio, and a leaked
one works forever with nothing on either side that would notice. So Vatio signs
its own request, and this endpoint requires the signature:

```bash
curl https://vatio.ai/.well-known/vatio-mint-key
```

```ruby
c.mint_public_key = ENV.fetch("VATIO_MINT_PUBLIC_KEY")
```

Required, not a switch. There is no flag to leave in the wrong position and no
way to hold the key and still accept unsigned requests — a verifier that treats
a missing signature as acceptable is one an attacker simply does not sign for.

Every call is checked for all four: that Vatio signed it (`ES256`, pinned), for
*this* workspace (`aud`), within the last minute (`exp`), asking about *this*
phone number (`body_sha256` over the exact bytes, read once). Anything else is
the same silent 404 as an unknown number.

Keep `mint_api_key` as well. The two answer different questions — *may you
ask* and *did Vatio ask this, just now* — so an attacker needs both, and the
one they cannot steal from you is the one you never hold.

### What this endpoint does on your behalf

Both of these are the reason the gem exists at all:

- **It refuses to run without `mint_api_key`.** An open mint endpoint signs an
  identity for any phone number anyone on the internet posts — that is account
  takeover for every customer you have, and Vatio cannot detect it from its
  side, because `auth.mint.headers` is optional in the manifest. So the check
  lives where it can be enforced, and it fails at boot rather than quietly.
- **It compares the key in constant time.** A plain `==` leaks the secret a
  byte at a time to anyone patient enough.

Match the phone number **exactly**, as Vatio sent it (E.164). No normalizing,
no `LIKE`, no stripping the country code to find a match: a loose lookup here
is one that can be steered into returning somebody else's account. If your
column holds local numbers, normalize *your* column, not the input.

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
