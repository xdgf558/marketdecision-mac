# Phase 1 fundamentals calculation candidate

This candidate adds an offline calculation kernel for ratios, point-in-time valuation distributions and seven-dimension fundamental scores. It consumes explicitly normalized financial periods and evidenced class prices/shares. It is not the completed Phase 1 research workflow or issuer taxonomy acceptance.

## Calculation behavior

- Exact Money arithmetic is retained through calculations; no automatic posting or binary-price conversion. Output pins the resolved model/parameter references and a versioned immutable snapshot of all calculation inputs, including selected periods, classification, split evidence and exact execution time; input views project that snapshot.
- Default PARAMETERS_V1 includes operating leases and excludes short-term investments. Debt slots are mutually exclusive; duplicate source use across debt slots is rejected. EV includes preferred equity/NCI; ROIC uses five quarter-end balances and the lease-interest adjustment. Missing tax for a profitable year cannot become the statutory fallback.
- Standard and ex-SBC FCF remain separate. Negative FCF retains its signed yield but does not produce a positive-denominator multiple. Market-cap P/E and quarterly-sum diluted-EPS P/E remain distinct. Unknown common-income, equity, debt or class inputs are never inferred as zero.
- Every expected class requires its own actual-share and price evidence on a consistent share-count date. Capitalization and historical inversion share exact class-ID completeness checks; a single wrong class cannot produce reference prices. Missing classes withhold capitalization; consolidated EPS is not applied across classes. Multiclass price inversion is unavailable without a separately implemented ratio-evidence contract.
- Historical samples require their own cutoff normalization, an evidenced open session and matching close price. Unknown availability (including current raw IEX adapter output), later financial versions, mixed feeds, duplicate days and today's normalization are not silently accepted as historical evidence.
- Historical ranking uses strict-less counts in the prior five calendar years, excluding the evaluation day. Scores require 252 independent observations. Price ranges separately require 504 valid trading days and two years of span; nearest-rank 20/50/80 labels survive yield inversion and price sorting.
- Seven dimensions retain missing leaves. Dimension coverage uses integer comparisons; total requires at least five dimensions and 70% original leaf weight. Confidence is input coverage, never investment probability. The heuristic is not empirically calibrated.
- The new exact-match dictionary is a separate version, adding 12 unambiguous dimensionless mappings checked against the [FASB 2025 taxonomy](https://xbrl.fasb.org/us-gaap/2025/elts/us-gaap-doc-2025.xml). Debt aggregates, total cash issuance, split-adjusted shares, industry/custom/dimensional facts still require issuer-specific evidence; the original dictionary is unchanged.

## Evidence and remaining work

- Clean public-copy local verification passed: 223 declarations, 222 executed tests and one real Keychain test NOT EXECUTED; 33 new tests in five suites. Debug/Release builds, effective permissions, Release isolation, 12 traceability and four UTC checks passed on macOS 27 / Xcode 27 beta 6 / arm64. The original-head CI is historical evidence only; updated exact-head CI is recorded on the PR.
- New synthetic suites exercise independent cash-flow/lease/capitalization expectations, missing/negative/zero inputs, multiclass completeness, version binding, normalized revision cutoffs, historical sample limits, strict-less/nearest-rank behavior and scoring coverage.
- Synthetic scaling vectors and 530 synthetic sessions are not ten real-company golden fixtures or proof of calendar/provider coverage.
- Full company-specific taxonomy, complete per-share/quarter-growth coverage, configurable nondefault debt models, multidimensional classes, real-issuer fixtures, model calibration and the research UI remain open. The default calculation candidate does not mark FIN parent tasks or TEST-002 complete.
- No application composition, UI, Keychain, production networking, supplier admission, live request, purchase, license or entitlement change is included. App remains synthetic DEMO. This kernel grants no live-analysis/PIT/backtest eligibility.
- Real Keychain remains NOT EXECUTED. Local clean-copy checks and subsequent exact-head hosted CI must be recorded separately. Merge does not close DATA-002, Phase 1/G1, DATA-000/G5 or authorize live wiring.

## Review correction

- Three full-project regression tests fail against the original implementation and pass after correction: current class-ID mismatch, incomplete saved input context and repeated model resolution. Nine new regressions include decoded-only replay, invalid/missing context, concurrent resolution, conflicting immutable definitions and sub-millisecond execution time.
- Reports require `fundamental-input.v1` snapshots and recompute using the exact resolved model references, never by deriving inputs from cached metrics. Historical results retain all submitted samples (including exclusions); scores can replay from those saved inputs. This adds no database schema, automatic save or backup migration, and makes no large-snapshot performance claim.
- Old candidate reports without complete snapshots and unknown snapshot versions are rejected, not filled with guessed defaults. General registry registration remains strict; the helper reuses only identical complete references and propagates conflicts.
