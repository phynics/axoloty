# Security policy

This policy tells you how to report a vulnerability in Axoloty and which
releases receive security fixes. Product version numbers and the deprecation
window are defined in [the versioning and deprecation policy](./docs/versioning.md).

## Supported versions

Axoloty is pre-1.0; [`VERSION`](./VERSION) identifies the current release and
the [support matrix](./docs/SUPPORT_MATRIX.md) records per-capability support.
While Axoloty is pre-1.0, only the latest release line receives security
fixes. Older release lines and unreleased development snapshots do not.

| Release | Security fixes |
|---|---|
| Latest release line (`0.Y`) | Yes |
| Older `0.x` release lines | No |
| `main` between releases | No |

After 1.0, the frozen products listed in
[the versioning and deprecation policy](./docs/versioning.md) receive security
fixes as follows:

| Release | Security fixes |
|---|---|
| Latest stable major version | Yes |
| Previous stable major version | For 12 months after the first stable release of its successor |
| Older major versions | No |

Deprecation is not a security-fix commitment; a release can be supported for
security while a deprecated symbol is already scheduled for removal.

## Reporting a vulnerability

Do not open a public issue for a suspected vulnerability.

1. **Preferred:** use GitHub private vulnerability reporting. Open the
   repository **Security** tab and choose **Report a vulnerability**. This
   creates a private security advisory that only maintainers can read.
2. **Fallback:** if private vulnerability reporting is unavailable, email
   `contact@atkn.me` with the subject `Axoloty security report`.

Include the affected release or commit, the impact, a minimal reproduction,
and any suggested fix or mitigation. A proof of concept helps but is not
required.

## What to expect

- We acknowledge a report within 7 calendar days.
- We provide an initial assessment and severity within 14 calendar days.
- We coordinate disclosure with you: we agree on a disclosure date before
  publishing, and we default to publishing once a fixed release is available.
- We credit reporters in the release notes unless the reporter asks to remain
  anonymous.

## Scope

In scope:

- the frozen 1.0 products: `Axoloty`, `AxolotyWire`, `AxolotyProtocol`,
  `AxolotyObjectModel`, `AxolotyStaticRuntime`, and `AxolotyMQTT`;
- the `coaty/3` and `axoloty/1` wire profiles;
- the external-consumer and embedded-consumer contracts under
  [`docs/embedded-consumer-contract.md`](./docs/embedded-consumer-contract.md).

Out of scope:

- vulnerabilities in third-party dependencies. Report them upstream, and tell
  us when Axoloty is affected.
- experimental products (`AxolotyZenoh`, `AxolotyZenohCore`,
  `AxolotyCoatyModels`, `AxolotyIoRouting`, `AxolotySensorThings*`, and the
  first-party `Apps/` and `Tools/` products) unless the finding also affects a
  frozen product.
- firmware and device integration in `phynics/axoloty-embedded`.

Denial-of-service and resource-exhaustion findings are in scope when they
break a documented bounded-resource, saturation, or admission guarantee.

## Safe harbor

We will not pursue or support legal action against researchers who make a
good-faith effort to follow this policy: avoid privacy violations and data
destruction, do not exfiltrate or retain more data than the report requires,
and give us reasonable time to ship a fix before disclosure.
