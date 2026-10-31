# New-product demand with partial pooling: cold-start forecasts on Online Retail II

**Status: complete run, with failures reported.** The primary test result is negative: at 4 weeks of history, the partial-pooling model (M4) does not beat a carry-forward forecast (M0). Several pre-declared failure criteria are triggered. The numbers below come from the CSV files in `results/`. Post-hoc checks, made after the test results were read, are labelled as post-hoc where they appear. A fresh re-run of the full pipeline on 2026-10-31 reproduced every results file (section 5.7).

## 1. The question

A product with only k weeks of sales history: how accurate and how well calibrated are forecasts of its weekly units 1 to 4 weeks ahead, and how does accuracy change as k grows from 1 to 26 weeks?

Sub-questions (DESIGN.md section 1):

1. Does partial pooling (a hierarchical model that shrinks each new product toward a prior built from similar past products) beat (a) carry-forward, (b) a model using only the product's own history, and (c) one global model?
2. Does any advantage shrink to zero as k grows?
3. Are the 80% and 50% prediction intervals calibrated, and does conformal recalibration fix any miscalibration?
4. Are the answers stable under changes to the launch rule, cleaning rules and model settings?

**Publication note.** Before this repository was published, its git history was rewritten once (commit author set to the GitHub noreply address, local file paths removed), so commit hashes differ from earlier local copies. Commit messages were not changed.

## 2. Data

- **Source:** Online Retail II, UCI Machine Learning Repository, dataset 502. A UK-based online wholesaler of gift products, 1 December 2009 to 9 December 2011.
- **Attribution:** Chen, D. (2012). Online Retail II [Dataset]. UCI Machine Learning Repository. https://doi.org/10.24432/C5CG6D
- **License:** Creative Commons Attribution 4.0 International (CC BY 4.0). The dataset page states this license; it was checked again on 2026-10-31.
- **What is committed:** no line-level data. The raw zip and xlsx (45.6 MB each) are in `data/raw/`, which is in `.gitignore`. The line-level intermediate table is in `data/interim/`, also gitignored. The tables in `results/` and `data/summary/` are derived from the dataset and modified: they are counts, filters, fitted results and per-product summaries. CC BY 4.0 requires that changes be stated, so this is stated here. `data/download.R` fetches the raw file and checks its size and sheet names. See `DATA.md` for the checksums and the full data dictionary.

### Cleaning (DESIGN.md section 3, applied as written)

| Step | Lines |
|---|---|
| Combined table after the sheet-overlap rule | 1,044,848 |
| Product-like StockCode (5 digits, optional letters) | 1,038,856 |
| Price above 0 and date inside the window | 1,032,918 |
| Lines kept in weeks 1 to 105 | 1,015,309 |

Source: `results/A_cleaning_and_launch_counts.csv`.

Other rules: cancellations (invoices starting with C) are not demand; weeks start on Monday; the burn-in is weeks 1 to 8; a launch is the first week with at least 1 unit after burn-in; products that sold in burn-in are excluded.

**Open decision for the owner (DCGS codes).** Rule 1 drops 34 `DCGS` codes (157 lines), some of which look like real products (for example `DCGS0058`, MISO PRETTY GUM). The rule was kept as written, so these codes are dropped in every result here. DATA.md section 6 asked for this decision before results were produced. Changing the rule now would change a pre-registered rule after the results were read, so any change belongs in a future protocol version. See section 9.

### Launch cohort

| | Development (launch week 9 to 52) | Test (launch week 53 or later) |
|---|---|---|
| Launch products | 985 | 676 |
| Usable at k = 4 (4 target weeks observed) | 832 | 579 |
| Usable at k = 12 | 694 | 394 |
| Usable at k = 26 | 480 | 215 |

Source: `results/A_usable_launches_by_k.csv`. The 1,661 launch products are listed in `results/A_launch_cohort.csv`. Because training rows must have their target week at or before week 52, development launches at larger k are fewer (DESIGN.md section 5, item 3).

## 3. Method, step by step

**Step 1. Weekly series.** For each launch product, weekly units are the sum of positive quantities on sales lines, from its launch week to week 105. Weeks with no sales are zero.

**Step 2. Forecast origin.** For a product launched in week L and a history length k, the origin is week L + k - 1. Only information from weeks up to the origin is used. The targets are the units in the 4 weeks after the origin.

**Step 3. Analog products (the prior).** For each product and origin, the analog set is the 40 launches (K = 40) that launched at least 4 weeks earlier than the product. That means every analog's first k + 4 weeks ended before the origin, so no analog's future is used. Similarity combines:
- cosine similarity of word vectors built from the product description (TF-IDF, with the weighting taken from burn-in descriptions only),
- the difference in log median price as of the origin,
- whether the launch was in the same calendar quarter.

Weights were fixed before any result (1, 0.5, 0.25) and were not tuned. K was chosen on development launches only (`results/C_dev_K_selection.csv`).

**Step 4. Models.** All models are scored on their predictive mean.

| Model | What it does in plain English |
|---|---|
| M0 | Forecast every future week as the last observed week's units (carry-forward). |
| M1 | Forecast the mean of the product's own k weeks. Interval width from its own variance. |
| M2 | Same mean as M1. The dispersion is estimated by maximum likelihood from the product's own weeks. For this model the point forecast is identical to M1. |
| M3 | One global negative binomial regression across all k, fitted on development targets. Inputs: log(1 + own mean), k, horizon, log price and the season of launch. |
| M4 | Partial pooling. Each product has its own level (a random intercept with spread tau). The level is estimated from the product's own weeks. The analog curve and log price also enter as fixed effects. Fitted by maximum marginal likelihood (empirical Bayes), separately for each k. |
| M5 | Analog-only: the mean units of the analog set at the same week since launch. No product data. |
| M5g | Global-average curve from development launches at the same week since launch. This is the baseline for failure criterion F2. |

**Step 5. Training rule.** Every training row has its target week at or before week 52. The test products' own information is used only as their history.

**Step 6. Test evaluation.** Pooled WAPE (sum of absolute errors divided by sum of actual units) over horizons 1 to 4. Bootstrap confidence intervals resample products (2,000 resamples). The primary contrast is M4 minus the better of M0 and M3 at k = 4.

**Step 7. Checks.** A leakage test rebuilds the features from data cut at weeks 40 and 90 and confirms they do not change (`results/C_leakage_test.csv`, all PASS). A split-conformal step recalibrates interval widths using development predictions only.

## 4. Results

### 4.1 Headline (k = 4, 579 test launches, pooled over horizons 1 to 4)

| Model | WAPE | Bias (units per row) | 80% coverage | 50% coverage |
|---|---|---|---|---|
| M0 carry-forward | **0.680** | -5.2 | 0.829 | 0.603 |
| M4 partial pooling (EB) | 0.838 | +8.8 | 0.858 | 0.601 |
| M5 analog-only | 0.964 | -4.3 | 0.892 | 0.576 |
| M5g global-average curve | 0.950 | -18.1 | 0.865 | 0.517 |
| M1 own mean | 1.175 | +38.4 | 0.729 | 0.508 |
| M2 own-series NB | 1.175 | +38.4 | 0.655 | 0.442 |
| M3 global NB | 1.271 | +55.7 | 0.959 | 0.797 |

Source: `results/B_cold_start_metrics_pooled_h1to4.csv`.

**Primary contrast (pre-registered).** M4 minus the better of M0 and M3 is **+15.8 percentage points** (WAPE 0.838 against 0.680). The product-clustered 95% bootstrap interval is **[-9.6, +66.1]**. M4 is worse than carry-forward, and the interval does not exclude zero. Source: `results/B_primary_k4_M4_vs_best_of_M0_M3.csv`.

Other contrasts at k = 4 (`results/B_secondary_contrasts_k4.csv`):
- M4 minus M1 = -33.8 points, interval [-93.0, -5.8]. Partial pooling beats the product's own mean.
- M4 minus M5 = -12.6 points, interval [-39.0, +36.9]. Not distinguishable.
- M5 minus M5g = +1.4 points, interval [-2.7, +5.6]. Analog matching is not better than the global average here.

### 4.2 Cold-start curve (pooled WAPE over horizons 1 to 4, test launches)

| k | M0 carry-forward | M3 global NB | M4 partial pooling | M5 analog-only | M5g global curve |
|---|---|---|---|---|---|
| 1 | 2.410 | 2.151 | 1.413 | 0.992 | **0.983** |
| 2 | **0.929** | 1.629 | 1.089 | 0.952 | 0.966 |
| 3 | **0.790** | 1.484 | 0.965 | 0.955 | 0.959 |
| 4 | **0.680** | 1.271 | 0.838 | 0.964 | 0.950 |
| 6 | **0.741** | 1.183 | 0.783 | 0.954 | 0.971 |
| 8 | **0.793** | 1.021 | not usable (see 5.1) | 0.963 | 0.941 |
| 12 | **0.802** | 0.907 | not usable | 0.907 | 0.921 |
| 16 | 0.988 | **0.798** | not usable | 0.961 | 0.921 |
| 20 | **0.699** | 0.723 | not usable | 0.894 | 0.902 |
| 26 | **0.650** | 0.771 | 0.695 | 0.902 | 0.988 |

Source: `results/B_cold_start_wape_curve.csv`. Bold marks the lowest WAPE in each row among the models that could be fitted. "Not usable" means the saved default-start M4 fit is failed (section 5.1), so no M4 value is reported. No confidence intervals were computed for k other than 4, so differences at other k are descriptive only.

At k = 1 the partial-pooling model beats carry-forward (M0) and the global NB model (M3), but not the analog-only (M5) or global-average (M5g) baselines, which have lower WAPE (0.99 and 0.98). At k = 6 carry-forward is slightly better than M4 (0.741 against 0.783). At k = 4 M4 is worse than carry-forward. The pattern is not monotone, and it is not evidence that partial pooling helps across the cold-start range.

### 4.3 Pooling diagnostics (component D)

- Between-product spread at k = 4: tau = 2.30 (log scale). A likelihood-ratio test against tau = 0 gives a statistic of 4,658 with boundary p below 0.001. The spread is clearly not zero. Source: `results/D_tau_test_by_k.csv`.
- Shrinkage at k = 4 (test products): the median share of prior spread removed by the product's own 4 weeks is 0.94. The posterior level is strongly correlated with the product's own log mean (correlation 0.81). Source: `results/D_shrinkage_summary_k4.csv`.
- The posterior level is therefore mostly driven by the product's own weeks. Analog information enters only through the fixed-effect curve, and its estimated coefficient is reported in `results/B_M4_fit_by_k.csv`.

### 4.4 Interval calibration (component E, k = 4)

| Model | Nominal | Dev coverage (raw) | Test coverage raw | Conformal scale c | Test coverage after recalibration |
|---|---|---|---|---|---|
| M4 | 80% | 0.889 | 0.858 | 1.00 | 0.858 |
| M4 | 50% | 0.679 | 0.601 | 0.67 | 0.421 |
| M0 | 80% | 0.881 | 0.829 | 0.75 | 0.744 |
| M3 | 80% | 0.972 | 0.959 | 1.00 | 0.959 |

Source: `results/E_calibration_before_after_conformal.csv`. For M4 the 80% intervals are already slightly wide on test data (coverage 0.86). Recalibration leaves them unchanged. The 50% intervals move the wrong way after recalibration on test data (0.60 to 0.42). The development predictions for M3 and M4 are in-sample, so their calibration is optimistic.

### 4.5 Robustness (component F, k = 4, time split)

| Variant | Setting | M4 WAPE | M0 WAPE | M3 WAPE | M4 minus best of M0/M3 (points) | 95% interval |
|---|---|---|---|---|---|---|
| baseline | as specified | 0.838 | 0.680 | 1.271 | +15.8 | [-9.6, +66.1] |
| burn13 | burn-in 13 weeks | 0.916 | 0.680 | 1.166 | +23.6 | [-8.6, +89.3] |
| launch5 | launch at 5 units | 0.756 | 0.680 | 1.180 | +7.6 | [-11.1, +40.5] |
| netted | returns netted | 0.612 | 0.681 | 0.897 | **-6.9** | [-11.7, -2.5] |
| uk_only | UK customers only | 0.993 | 0.701 | 1.540 | +29.2 | [-8.9, +108.2] |
| drop_top1pct | drop top 1% by dev volume | 0.835 | 0.680 | 1.261 | +15.6 | [-9.6, +65.5] |
| poisson | Poisson likelihood | 1.228 | 0.680 | 0.831 | **+54.8** | [-1.9, +176.3] |
| K10 | 10 analogs | 0.927 | 0.680 | 1.271 | +24.7 | [-8.4, +92.7] |
| K20 | 20 analogs | 0.837 | 0.680 | 1.271 | +15.8 | [-9.1, +65.2] |
| random_split (warning check only) | random product split, no time cutoff | 0.900 | 0.747 | 1.080 | +15.3 | [-14.9, +72.5] |

Source: `results/F_robustness_k4.csv`. The baseline row reproduces the headline numbers exactly, which confirms the run is repeatable.

Two variants change the answer:
- **Returns netted:** M4 is ahead of carry-forward by 6.9 points, and the interval excludes zero. The sign flips. Section 5.5 shows that one product dominates M4's error in the baseline, and it had a large order cancelled the same day. Section 5.8 shows that the netted sign flip remains when that product is removed from the test set.
- **Poisson:** M3 beats M4 (the ranking changes), and the M4 gap widens to 54.8 points.

The random product split did not inflate M4. In that run, M4 is also worse than carry-forward.

### 4.6 Pre-registered failure criteria (DESIGN.md section 6)

| Criterion | Triggered? | Evidence |
|---|---|---|
| F1: M4 beats the better of M0 and M3 at k = 4 by 3+ points, interval excluding zero | **Yes** (not met) | +15.8 points, interval [-9.6, +66.1] |
| F2: analog-only M5 not better than global-average M5g at k = 4 | **Yes** | WAPE 0.964 against 0.950 |
| F3: tau indistinguishable from zero | No | LRT boundary p < 0.001 at k = 4; tau = 2.30. A stricter check (section 5.8) also rejects zero. |
| F4: 80% interval after recalibration outside 0.72 to 0.88 (k = 4) | No | 0.858 |
| F5: sign or ranking of M4 against M0 and M3 changes in any variant | **Yes** | Changed in `netted` (sign and ranking) and `poisson` (ranking) |
| F6: fewer than 500 test launches at k = 12 | **Yes** | 394 test launches |
| F7: Bayesian convergence fails | Not applicable (Bayesian fit not run, see 5.4). The pre-registered optimiser-code check for the empirical Bayes fit passed at every k. | Code 0 at all k |
| F7b (post-hoc, see 5.1): M4 fit failed | **Yes** at k = 8, 12, 16, 20 (default start) | Log-likelihood below the nested model, tau above 10. Section 5.1 gives a follow-up check at k = 8. |

Sources: `results/B_failure_criteria_F1_F3_F6_F7.csv`, `results/E_failure_criterion_F4.csv`, `results/F_failure_criterion_F5.csv`, `results/B_posthoc_M4_fit_sanity_by_k.csv`.

### 4.7 Simulation layer (removed)

The simulation layer (component G) was removed from the pipeline on 2026-10-30, because it generated synthetic products, and the project rule is that synthetic data does not stand in for a real result (DESIGN.md section 12.1). No simulated number is reported in this README. Its earlier code and outputs remain in the git history.

## 5. What failed, and post-hoc checks

### 5.1 M4 did not fit at k = 8, 12, 16 and 20 (default start)

For these four values of k the optimiser returned code 0, but the fitted random-effect spread (tau) ended between 3.8e7 and 1.6e9. The fitted log-likelihood was lower than the nested model with no random effect, which cannot happen at a true maximum. These saved fits are reported as failed (DESIGN.md section 6, F7). M4 values for these k are not reported, and the cold-start curve shows them as "not usable". The `posthoc_failed` labels in `results/` and in the figures refer to these saved fits.

This was found after the test results were read. It is a post-hoc finding, and it is labelled as such. The pre-registered F7 check (optimiser code only) did not catch it.

**Follow-up (post-hoc, section 5.8).** At k = 8 the same 61-point grid and three other starting values for tau reach a fit with tau 2.35 and log-likelihood -28,546. That log-likelihood is 4,977 units higher than the saved default-start fit (-33,523) and higher than the nested null (-31,665). So the saved k = 8 fit is a local optimum of the default start, not evidence that the model cannot be fitted to these data. The same check was not run at k = 12, 16 and 20. The "not usable" entries therefore describe the saved fits only, and the M4 values at k = 8 to 20 are not established either way. A refit with multiple starts would change reported numbers, so it was not done in this pass. It is listed in section 9 for the owner.

The fits at k = 1 to 6 and k = 26 pass the same check. k = 4, the headline, passes, and the follow-up gives the same tau at k = 4 from every start.

### 5.2 Partial pooling does not beat carry-forward at the headline point

At k = 4, M4 is worse than M0 by 15.8 points, with a wide interval. The result holds in the baseline, in K = 10 and K = 20, and in the random-split warning run. It reverses in the returns-netted variant. The honest reading is that the sign is not stable across reasonable choices.

### 5.3 Global and analog-only priors do not beat the global average

M5 (analog-only) is 1.4 points worse than M5g (global average) at k = 4. F2 is triggered. Analog matching carries no measurable information on this data at k = 4.

### 5.4 Not run

- **Bayesian (cmdstanr) fit.** CmdStan is not installed. glmmTMB could not be installed (its dependencies `nloptr` and `lme4` failed to build). The empirical Bayes fit was used instead (see 6.1).
- **Bounded or multi-start refit of M4 at k = 8 to 20.** Not done in this pass (section 5.1, section 9).
- **Two component C ablations.** Text similarity off (time and price only), and M4 with no analog term. Neither was run (DESIGN.md section 12.8).

### 5.5 Post-hoc: one product dominates M4's error at k = 4 (descriptive, not a new test)

This check was added after the test results had been read. It is labelled post-hoc in `src/10_posthoc_concentration.R`. It does not change any pre-registered verdict.

- One product (StockCode 23166, a ceramic storage jar) accounts for **26.6%** of M4's total absolute error at k = 4. Its M4 errors sum to 34,097 units over the four target weeks (about 8,524 units per week). Its actual units in those weeks are 0 (`results/X_posthoc_concentration_by_product_k4.csv`, the product is labelled there by an internal id, 1012).
- The cause is in its first weeks. A single invoice of 74,215 units was placed on 18 January 2011, and the same day a credit invoice (C541433) reversed all 74,215 units (`results/P_data_facts.csv`). Primary demand (rule 3) counts the sale and not the credit, so that week is a launch week with 74,215 units. Carry-forward uses only the last week, which is 0, so it is not affected. M4 uses the whole four-week history, so one very large week pulls its level up.
- Excluding that one product from both models (like-for-like): M0 WAPE is 0.680 (unchanged) and M4 WAPE is 0.615. On that reduced set, M4 would be ahead of carry-forward by about 6.5 points. Excluding the top five M4-error products gives M4 0.613 against M0 0.681.
- The result is therefore sensitive to one product. The pre-registered answer (F1 not met) stands, because the excluded product was not chosen in advance. Any claim that partial pooling helps at k = 4 on this data would depend on this single product.

Sources: `results/X_posthoc_concentration_summary_k4.csv`, `results/X_posthoc_concentration_by_product_k4.csv`.

### 5.6 Post-hoc known-truth benchmark on steady products (not a cold-start test)

Written and run after the test results were read (DESIGN.md section 11). Products that sold in at least 45 of the 52 development weeks (638 products) are given a pretend launch at week 53, 60, 67 or 74. Their history is the real units from the pretend launch to the origin, and their truth is the real units in the next four weeks. The benchmark therefore tests forecasting from k weeks of a steady product, not from a real launch. DESIGN.md section 11.6 expected that the launch-shape terms in M4, M5 and M5g would disadvantage them, and that carry-forward might win for that reason alone. The consistency checks against the saved fits pass (`results/KT_fit_consistency_check.csv`), and the analog sets for real test launches are unchanged when the pretend launches are added (100 of 100).

k = 4, pooled over horizons 1 to 4, 638 products (`results/KT_known_truth_by_model_k.csv`):

| Model | WAPE | 80% coverage |
|---|---|---|
| M0 carry-forward | 1.027 | 0.763 |
| M1 own mean | 0.923 | 0.661 |
| M2 own-series NB | 0.923 | 0.604 |
| M3 global NB | 1.088 | 0.957 |
| M4 partial pooling | **0.793** | 0.808 |
| M5 analog-only | 1.127 | 0.904 |
| M5g global-average curve | 1.178 | 0.904 |

The secondary check of the section 5 rule gives M4 minus the better of M0 and M3 = -23.4 points, interval [-31.8, -13.3]. This is labelled as a secondary check, not a confirmatory test (`results/KT_primary_k4_contrast.csv`). M4 minus M1 is -13.0 points, interval [-18.4, -8.3]. By pretend-launch week (`results/KT_by_Lstar_k4.csv`), M4 beats M0 at weeks 60, 67 and 74 (0.621 against 0.787, 0.740 against 1.341, 0.641 against 0.871) but not at week 53 (1.176 against 1.122).

This result is the opposite of the direction DESIGN.md section 11.6 expected for M4, and it does not bear on cold start. It does not support or refute partial pooling for new products, because the products are steady sellers that are not new and their history does not have a launch shape.

### 5.7 Post-hoc reproducibility re-run (2026-10-31)

The full chain was re-run from a fresh copy of the repository (tracked and untracked source files only) in a scratch folder. `data/download.R` re-downloaded the zip from UCI and passed its size and sheet-name checks. All 15 steps finished with exit code 0, in about 44 minutes on an 8-core Mac (observed, not a benchmark). The slowest steps were `src/13` (about 18 minutes), `src/03` (about 11 minutes) and `src/11` (about 6 minutes).

`src/14_reproducibility_check.R` compares every CSV, TXT and PNG in `results/`, `data/summary/` and `figures/` with the fresh output. Results are in `results/R_reproducibility_check.csv`:

- 51 files match numerically (exact for text and integers, relative tolerance 1e-9 for other numbers). This includes every headline, failure-criterion, calibration and robustness file, so every verdict in section 4.6 is unchanged.
- `results/Q_quadrature_check.csv` matches in every value except the `secs` timing column. The repository keeps the original timing.
- `data/summary/prep_log.txt` differs only in its run timestamp line.
- `figures/fig2_interval_coverage.png` differs in bytes. Its numbers come from `results/E_calibration_before_after_conformal.csv`, which matches. `figures/fig1_cold_start_wape.png` is byte-identical.
- `results/PROTOCOL_LOCK.txt` is not produced by the pipeline and is not in the fresh copy, as expected.

### 5.8 Other post-hoc checks

All of these are labelled post-hoc and none changes a pre-registered verdict.

- **Stricter F3 check** (`results/F3_nested_spread_check_k4.csv`, `src/13`). When the product's own mean is included in both the random-effect model and its null, tau = 0.58 and the likelihood-ratio statistic is 861 (boundary p about 1e-189). The spread is still clearly not zero. The original F3 row is kept unchanged.
- **Quadrature grids at k = 4** (`results/Q_quadrature_check.csv`). Grids of 61, 121, 201, 321 (on [-8, 8]) and 401 points give tau between 2.2982 and 2.2983 and test WAPE between 0.837552 and 0.837554.
- **Multi-start at k = 4 and k = 8** (`results/S_multistart_check.csv`). Starting tau values 0.05, 0.5 and 5 give the same answer at each k. At k = 4 the fit is tau 2.298. At k = 8 it is tau 2.354 with log-likelihood -28,546 (section 5.1).
- **Returns netted, product 23166 removed from the test set** (`results/N_netted_excluding_23166_k4.csv`). M4 0.611 against M0 0.681, a difference of -7.0 points. The sign flip in the netted variant remains.
- **Leave-one-product-out at k = 4** (`results/P_leave_one_product_out_summary_k4.csv`). Removing any one of the 579 test products moves the baseline difference between -6.5 and +16.8 points. Only the removal of product 23166 flips the sign.
- **Conformal step check** (`results/P_conformal_step_check_k4.csv`). Demand is in whole units, so coverage is a step function of the scale c. The chosen c is the smallest value on the 0.01 grid that reaches the nominal development coverage (DESIGN.md section 9, A9).

## 6. Deviations from DESIGN.md

All deviations were written as dated amendments in `DESIGN.md` section 10 before the test-set evaluation was run (commit `d3dad85` before the history rewrite; lock recorded in `results/PROTOCOL_LOCK.txt`). Later amendments are in DESIGN.md section 12. The main ones:

1. **6.1 Fitting method.** M4 is maximum marginal likelihood with a random intercept (empirical Bayes), integrated on a 61-point grid. The Bayesian fit with 4 chains was not run.
2. **6.2 Analog offset.** The analog curve is a fixed covariate with an estimated coefficient, not a fixed offset of 1.
3. **6.3 IDF weights.** Descriptions were weighted using burn-in text only, so no later text enters the similarity.
4. **6.4 Fallback.** Products with no analog use the global average curve. These are the 166 development launches with no earlier launch to draw from (`fb_analog_train` in `results/B_per_k_run_info.csv`). No test product needed the fallback.
5. **6.5 Dispersion.** M0, M5 and M5g use the dispersion from the pooled M3 regression. M1 and M2 use their own.
6. **6.6 Robustness on top-1% products.** Volume is measured in development weeks only, so test-period volume does not affect the cohort.
7. **6.7 Post-hoc labelling.** The M4 failure check in section 5.1 was added after the test results were read. It is labelled post-hoc in `src/lib_pipeline.R` (`m4_posthoc_failed_k`), `src/05_cold_start_eval.R`, `src/06_calibration.R` and `src/09_figures.R`, and in `results/B_posthoc_M4_fit_sanity_by_k.csv`. The metric and calibration cells of the four failed fits are blank in the CSVs.
8. **6.8 Simulation removed.** Component G was removed (section 4.7).
9. **6.9 Run-time column.** The run time in `results/F_robustness_k4.csv` was moved to the console log, so that re-runs give identical CSV output (`src/07_robustness.R`).
10. **6.10 Stricter F3 and other checks.** Added after the results were read, labelled post-hoc (section 5.8).
11. **6.11 Regeneration script.** `src/14` was first written to compare with a git commit. It was replaced by `src/14_reproducibility_check.R`, which compares two folders and needs no git history.

## 7. Limits

- **One retailer, two years.** This is one UK wholesaler, mostly business customers, from 2009 to 2011. The results describe this retailer and period only.
- **Sample size.** The test set has 579 products at k = 4, but only 394 at k = 12, below the 500 that DESIGN.md asks for. The k = 12 point is reported and not interpreted (F6).
- **Heavy-tailed demand.** Launch products have mean weekly units from about 0.01 to about 1,690 (`results/P_data_facts.csv`). WAPE is dominated by the largest products, so the bootstrap intervals are wide.
- **Seasonality.** Development launches span launch weeks 9 to 52. Test launches in December and January fall outside that range, and the season term extrapolates there.
- **Calibration in-sample.** Development predictions for M3 and M4 are in-sample, so the conformal scale is optimistic for them.
- **Product codes.** Codes are the retailer's own, and the description text is the retailer's wording.
- **Launch definition.** A "new product" here means the first sale after burn-in, not a real product launch.
- **Known-truth benchmark.** Steady products only, one pretend-launch week per product (section 5.6).

## 8. Reproduce

Run from the project root, in this order. The observed run on 2026-10-31 took about 44 minutes on an 8-core Mac (section 5.7).

```
Rscript data/download.R
Rscript data/prep_raw.R
Rscript data/feasibility_check.R
Rscript src/01_clean_and_launches.R
Rscript src/02_features_analogs.R
Rscript src/03_models_baselines.R
Rscript src/04_pooling_diagnostics.R
Rscript src/05_cold_start_eval.R
Rscript src/06_calibration.R
Rscript src/07_robustness.R
Rscript src/09_figures.R
Rscript src/10_posthoc_concentration.R   # post-hoc descriptive check (section 5.5)
Rscript src/11_known_truth_benchmark.R   # post-hoc known-truth benchmark (section 5.6)
Rscript src/12_posthoc_checks.R          # post-hoc checks (section 5.8)
Rscript src/13_m4_numerical_checks.R     # post-hoc numerical checks (section 5.8)
Rscript src/14_reproducibility_check.R <folder>   # compares a re-run with results/ (section 5.7)
```

Packages: `readxl`, `data.table`, `MASS`, `Matrix`, `ggplot2`. The fixed seed is 20261029. Intermediate files are written to `data/interim/` (gitignored). `src/11` and `src/13` read `data/interim/run_baseline.rds`, which `src/03` writes.

Figures: `figures/fig1_cold_start_wape.png` (WAPE by k; the M1 line sits under the M2 line because their point forecasts are identical, and the M4 line has gaps at k = 8 to 20) and `figures/fig2_interval_coverage.png` (80% coverage before and after recalibration).

## 9. Open items (for the owner)

1. **DCGS rule (section 2).** Decide whether DCGS codes count as products in a future protocol version. The current results drop them.
2. **M4 at k = 8 to 20 (section 5.1).** The saved default-start fits are failed, but the k = 8 follow-up shows a better optimum exists. A multi-start refit for k = 8 to 20 would be a labelled post-hoc sensitivity analysis and would change the reported curve. Decide whether to do it and how to publish it.
3. **Bayesian fit.** Not run, because CmdStan is not installed.
4. **Commit attribution.** The publication commits end with `Co-Authored-By: Claude Sonnet 5.5`, as the owner's instruction specified. Commits made earlier end with `Claude Haiku 5.5`, as the session attribution rule required, and the rewrite did not change their messages. Confirm which model name to use going forward.
5. **Cancelled bulk orders (section 5.5).** Rule 3 counts a sale that was later fully reversed. Whether to treat such lines differently is a cleaning decision for a new, pre-registered protocol version, not a change to this one.
6. **Ablations not run (section 5.4).**

## 10. Repository layout

```
DESIGN.md              protocol, with dated amendments in sections 10 to 12
DATA.md                data source, checksums, dictionary, cleaning counts
README.md              this file
data/download.R        fetches the zip (raw files are gitignored)
data/prep_raw.R        sheet overlap rule, summary CSVs
data/feasibility_check.R
src/00_config.R        fixed settings and robustness variants
src/lib_pipeline.R     shared functions (cleaning, analogs, models, evaluation)
src/01 ... src/07      components A to F, in order
src/09_figures.R       figures
src/10 to src/13       post-hoc checks (sections 5.5, 5.6, 5.8)
src/14_reproducibility_check.R   compares a re-run with results/ (section 5.7)
results/              every number in this README comes from a CSV here
figures/              final figures (R, ggplot2)
```
