# Phase 1 calendar and event review

Status: implementation candidate for review. This document does not approve a provider or close Phase 1/G1.

## Scope

This change delivers the Phase 1 foundation of `P1-CALENDAR` (`DATA-007` and `DATA-008`) as one coherent slice:

- closed capabilities and endpoints for market calendars, earnings calendars, and dividends;
- XNYS/XNAS session records with regular, early-close, closed, and explicit unknown states;
- earnings and ex-dividend records with confirmed, estimated, and explicit unknown dates or timing;
- a typed provider-acceptance pipeline that preserves the exact response bytes before storage;
- durable `business.p1.v2` tables and current/point-in-time queries for sessions and company events.

The bundled `2024–2028 v1` calendar is a versioned curation of published [NYSE hours and calendars](https://www.nyse.com/trade/hours-calendars), the [Nasdaq holiday schedule](https://www.nasdaq.com/market-activity/stock-market-holiday-schedule), and the official 2025-01-09 closure notices. It covers both exchanges for every calendar date in the declared range, including weekends, observed holidays, early closes, and the National Day of Mourning. New temporary closures or schedule changes require a new manifest version.

## Provider and point-in-time boundaries

`AcceptedProviderPayload` can only be constructed after the provider session accepts the exact request/response cycle. The raw payload reference, bytes/hash, evidence, license declaration, provider, feed, endpoint, capability, and configuration/entitlement versions are checked again before the typed store ingests a record. A substituted raw payload or mismatched endpoint is rejected before persistence.

The bundled manifest has an explicit publication availability of 2026-09-11. The code does not claim that this compiled view was available at an earlier cutoff. A point-in-time query before that availability returns incomplete coverage instead of falling back to the current calendar.

The Alpha Vantage earnings/dividend adapter is a free-key candidate. The API key and HTTP transport are supplied by the caller; no key is embedded, logged, or persisted. Provider throttling and error payloads are failures, not empty successful calendars. When the source does not supply reliable availability evidence, records remain availability-unknown: they may be shown in a current view, but they are excluded from point-in-time research.

No live API call, real API key, plan-limit test, license qualification, or application-runtime wiring is included. The presence of this adapter does not make Alpha Vantage or its data qualified for production use.

## Storage and behavior

Calendar ingest requires a complete date-by-market page for the requested interval. Closed, unknown, missing, or incomplete sessions cannot validate an expiry. Session times are constructed in New York time, including daylight-saving changes; regular sessions close at 16:00 and declared early sessions at 13:00.

Company-event queries select the version available at the cutoff before applying the requested event-date filter. A later reschedule therefore cannot make an older event version reappear in historical results. Unknown event dates remain explicit, zero dividends remain distinct from missing amounts, and exact source bytes stay referenced by the stored rows. Cache purge retains source documents still used by calendar or company-event records.

## Verification

The fixed public catalog contains 150 tests in 27 suites: 149 are required and executed, while the existing real Keychain integration remains explicitly `NOT EXECUTED`. Eight new tests cover unexpected closure/early close/DST, complete calendar persistence and restart, incomplete-page rejection, raw-payload substitution, earnings estimate/unknown handling, zero and unknown dividends, provider throttling, and event rescheduling across point-in-time revisions.

Debug and Release builds, module boundaries, traceability, UTC invariance, production entitlements, and Release test-marker isolation are checked separately. This slice changes no UI or production entitlement.

## Exclusions

This change does not implement SEC statement import, live quotes, financial models, research screens, ZIP backup/restore, options-event analytics, alerts, procurement, or the private acceptance-case set. `DATA-008` still has later Phase 3 consumers.

Merging this review would accept this implementation slice only. It would not close Phase 1/G1, qualify a provider or license, close `DATA-000`/G5, or start another Phase 1 node. Full specifications, task maps, source-research notes, evidence logs, and project memory remain local and are not part of this repository.
