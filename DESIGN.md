# DESIGN: new-product-demand-partial-pooling

Status: design only, written 2026-10-29. No results exist yet. The evaluation protocol in section 5 must be committed and locked before any test-set number is produced.

## 1. Research question

When a product has only k weeks of sales history, how accurate and how well calibrated are forecasts of its weekly units for the next 1 to 4 weeks, and how does that accuracy change as k grows from 1 to 26 weeks?

Sub-questions:

1. Does partial pooling (a hierarchical model that shrinks each new product toward a prior built from similar past products, called "analog products") beat (a) a naive carry-forward forecast, (b) a per-product model that uses only that product's own history, and (c) one global model with no product-level terms?
2. Does the advantage, if any, shrink to zero as k grows (the "cold-start curve")?
3. Are the 80% and 50% prediction intervals calibrated, and does a conformal recalibration step fix any miscalibration without hurting sharpness?
4. Are the answers stable under reasonable changes to the launch definition, cleaning rules and model settings?

A null or negative answer to any sub-question is an acceptable result and will be reported as such.

## 2. Dataset

Primary dataset: Online Retail II (UCI Machine Learning Repository, dataset 502).

- Dataset page: https://archive.ics.uci.edu/dataset/502/online+retail+ii
- Direct file: https://archive.ics.uci.edu/static/public/502/online+retail+ii.zip
- License: Creative Commons Attribution 4.0 International (CC BY 4.0). The dataset page states this license. Reuse is allowed with attribution. Attribution goes in the README.
- Content: one transactional xlsx file, `online_retail_II.xlsx`, with two sheets, `Year 2009-2010` and `Year 2010-2011`. Columns include Invoice, StockCode, Description, Quantity, InvoiceDate, Price, Customer ID and Country. The dataset page describes the coverage as 1 December 2009 to 9 December 2011, from a UK-based online wholesaler of gift products. The download script will confirm this date range.

Verified on 2026-10-29 by running the commands below:

| Check | Command or method | Result |
|---|---|---|
| Reachable | `curl -sL` on the direct zip URL | HTTP 200 |
| Size | `curl` download, then byte count | 45,622,418 bytes (about 45.6 MB) |
| Archive contents | `unzip -l` | one file, `online_retail_II.xlsx`, 45,622,278 bytes |
| Sheets | parse `xl/workbook.xml` inside the xlsx | `Year 2009-2010`, `Year 2010-2011` |
| Rows | count `<row` tags in each sheet XML (includes header) | 525,462 and 541,911 (about 1.07 million transaction lines in total) |
| Date ranges | read the InvoiceDate column (E) in each sheet XML | sheet 1: 1 Dec 2009 to 9 Dec 2010. Sheet 2: 1 Dec 2010 to 9 Dec 2011 |
| Overlap | count lines dated 1 to 9 Dec 2010 in each sheet | 22,523 lines in each sheet, the same count. The 9 days appear in both sheets |
| Malformed dates | count InvoiceDate values below serial 1000 (year 1899) | 1 in each sheet. These are dropped by the window filter |
| License | read the dataset page | CC BY 4.0 |

Correction note (2026-10-29, added after the data acquisition step; the original text above is kept as written):

- The row "Malformed dates" above is wrong. A direct check of the raw sheet XML (all numeric values in column E, both sheets) found no value below serial 1000. The smallest serials are 40,148.32 (sheet 1) and 40,513.35 (sheet 2). No 1899 dates exist, and the window filter drops 0 rows. The earlier count of 1 per sheet is not reproduced. See DATA.md section 9.
- The "about 1.07 million lines" is the raw total (525,461 + 541,910 = 1,067,371). After the sheet-overlap rule (section 3, rule 0), the combined table has 1,044,848 lines (DATA.md section 4).
- The `digest` package in `data/download.R` was replaced by the system `shasum` command, so the download script needs no extra R package.
- The dataset citation and CC BY 4.0 license were re-checked on the UCI page on 2026-10-29 (DATA.md section 1).

Large enough: about 1.07 million lines, about 2 years of weekly history (roughly 104 weeks), and a product catalogue that the pipeline will count. Launches (new products) are counted by the pipeline, not assumed here. The design requires at least 500 test launches that have 12 weeks of history plus 4 weeks of targets observed. If the data does not reach 500, the protocol still runs, the shortfall is stated in the README, and no claim is made beyond the sample.

Size rule: the zip (45.6 MB) and the xlsx (45.6 MB) are above the 5 MB limit. They are never committed. `data/download.R` fetches them into `data/raw/`, which is in `.gitignore`. Only the cleaned weekly table, if it is under 5 MB, may be written to `data/processed/`. Otherwise the pipeline rebuilds it from the raw file.

Backup datasets (not used unless the primary fails):

- M5 (Walmart item-store daily sales). Mirror: https://github.com/Nixtla/m5-forecasts/raw/main/datasets/m5.zip. Verified 2026-10-29: the URL redirects and the final response is HTTP 200, size about 50.2 MB. The license for this competition data is governed by the Kaggle competition rules. I did not verify those terms for research reuse, so M5 is not the primary dataset. It is a fallback only if its terms are checked and found compatible.
- Rossmann and Favorita (Kaggle). Direct Kaggle URLs returned HTTP 404 to unauthenticated curl, so reachability and terms are not verified. Excluded for now.

Limits of this dataset (to be stated in the README):

- One UK wholesaler, not a store chain. Customers are mostly businesses.
- "New product" means "first sale in this dataset after the burn-in period". It does not mean the product was launched that week.
- Two years of history, and the data is from 2009 to 2011.
- Product codes are the retailer's own codes.

## 3. Data cleaning and definitions (fixed before results)

These rules are written down now and are not changed after seeing test results.

0. Sheet overlap. Sheet 1 (`Year 2009-2010`) and sheet 2 (`Year 2010-2011`) both contain the same 22,523 lines dated 1 to 9 December 2010. Rule: take sheet 1 for InvoiceDate before 1 December 2010, and sheet 2 for InvoiceDate from 1 December 2010 onward. Then the 9 overlapping days are counted once. The pipeline also checks that the two sheets agree on those 9 days (same line count) and stops if they do not.
1. Keep lines whose StockCode looks like a product code (5 digits, optionally followed by letters). Drop non-product codes such as POST, D, M, BANK CHARGES, PADS, DOT and similar service codes.
2. Drop lines with Price <= 0, missing StockCode, or an InvoiceDate that does not fall inside 1 December 2009 to 9 December 2011 (this removes the malformed 1899 dates).
3. Invoices starting with "C" are cancellations. Primary demand = sum of positive Quantity on sales lines. Returns are excluded from demand. Robustness variant: net of returns.
4. Week = Monday-start calendar week. Week 1 starts Monday 30 November 2009. The last partial week in the data is dropped.
5. Series = one row per StockCode per week, units = primary demand. Zeros are filled in for weeks with no sales. Each product's series starts at its first week of data.
6. Burn-in = weeks 1 to 8 (December 2009 to late January 2010). A product is eligible to be a "launch" only if it has zero primary demand in the burn-in. This removes products that were already selling before the window and so are not truly new.
7. Launch week L_p = first week with at least 1 unit of primary demand after the burn-in. Launch-eligible products must have L_p >= 9.
8. Each product has one description for analog matching: the most frequent Description value among its lines dated on or before the origin week. Log median price for the same product is computed from prices in weeks on or before the origin week only.

## 4. Analysis components (at least 4 distinct)

Each component is a separate script in `src/` with its own output in `results/`.

**Component A. Cleaning, launch detection and cohort construction.** Builds the weekly table, applies the rules in section 3, counts launches, and reports how many launches reach each value of k. Also writes the list of launch products and their weeks, so the other components use the same cohort.

**Component B. Cold-start curve (main result).** For k in {1, 2, 3, 4, 6, 8, 12, 16, 20, 26}, each test launch is forecast from its first k weeks, with targets at horizons h = 1, 2, 3, 4. Models compared:

- M0 Naive carry-forward: last observed week's units.
- M1 Own mean: mean of the product's own k weeks, with a negative binomial interval from its own variance.
- M2 Per-series negative binomial: separate model per product fitted to its own weeks only.
- M3 Global negative binomial GLM (complete pooling): one model across all products, with features log(1 + mean of first k weeks), k, h, log median price and the week-of-year of launch. Fitted on development launches only.
- M4 Partial pooling, hierarchical negative binomial (primary model): log mean for product p at horizon h is a global intercept plus feature effects, plus a product random effect u_p ~ Normal(0, tau^2), plus an analog prior offset (component C). Fitted by Bayesian sampling (cmdstanr preferred) or by empirical Bayes (glmmTMB) if cmdstanr is not available. The fitting method is fixed now: primary = cmdstanr, with 4 chains, 2,000 iterations per chain after 1,000 warm-up, and a check that R-hat < 1.01 and no divergent transitions. If these checks fail, that run is reported as failed, not repaired by changing settings.
- M5 Analog-only prior (ablation): forecast = the analog cohort's mean weekly curve at the same weeks-since-launch, with no product data.

Metrics for each model, k and h:

- WAPE (weighted absolute percentage error) = sum of absolute errors divided by sum of actual units.
- Bias = mean of (forecast minus actual).
- 80% and 50% interval coverage, and mean interval width.
- Interval score for the 80% interval (Gneiting and Raftery) and an approximate CRPS from predictive draws.

The primary headline number is WAPE for M4 versus M0 and M3 at k = 4, pooled over h = 1 to 4, with a product-clustered bootstrap confidence interval (2,000 resamples, resampling products, not rows).

**Component C. Analog prior construction.** For each origin, the analog set is the K most similar launches that happened before the origin week and whose weeks 1 to k + 4 since launch all end on or before the origin week. An analog's future weeks are never used, even though they exist in the data. Similarity combines (a) cosine similarity of TF-IDF vectors built from Description text, (b) absolute difference in log median price, and (c) same launch quarter. Weights and K are chosen on development launches only. Ablations: text similarity off (time and price only), K = 10, 20 and 40, and no analog prior at all (M4 with the analog offset removed, which becomes a random-intercept model).

**Component D. Pooling diagnostics.** Estimates tau (the between-product spread) and reports how far each product's forecast moves from its own mean toward the prior (the shrinkage factor). Also checks whether the posterior tau is distinguishable from zero. If tau is near zero, the hierarchical model reduces to a global model, and this is reported as a finding.

**Component E. Interval calibration.** Reports coverage and sharpness by k and h for each model. Then applies split-conformal recalibration: development-set residuals set a multiplicative width factor per k. The recalibrated intervals are evaluated once on test launches. Before and after numbers are both reported.

**Component F. Robustness grid.** Each variant re-runs components B and E with one setting changed: burn-in of 13 weeks instead of 8; launch threshold of 5 units instead of 1; returns netted against demand; UK customers only; excluding the top 1% of products by volume; Poisson instead of negative binomial; K = 10, 20 and 40; and a random product split instead of the time split. The random split is run only as a warning check, to show how much a leaky split would overstate performance. A headline result is called fragile if its sign or its ranking of M4 against M0 and M3 changes under any variant.

**Component G. Simulation layer (labelled method check, not a demand result).** Generates synthetic products with a known tau and known analog structure, then checks that component D recovers tau and that M4 beats M2 when pooling should help. Output files are named `sim_*` and every figure and table from this component carries the label "SIMULATION". Simulation results are never reported as evidence about real demand.

**Real-data known-truth benchmark (within component B).** Mature products (sales in every week of the window) are truncated to pretend they launched at a chosen week. Their later weeks are real observed demand, so they serve as a second held-out set with known truth. This is reported separately from the launch test set.

## 5. Evaluation protocol (fixed before any results)

1. Time split on launch week. Development launches: L_p between week 9 and week 52 (December 2009 to November 2010). Test launches: L_p from week 53 onward. Test launches are used only after all hyperparameters are frozen.
2. Rolling origins: for each test launch and each k, the origin is week L_p + k - 1. Information used at the origin is restricted to weeks up to the origin. No product, analog or hyperparameter may use a later week. A leakage test in `src/` checks this by recomputing features after truncating the data at the origin and confirming the features are unchanged.
3. Training-row cutoff for every fitted model (M2, M3, M4, the analog weights and the conformal scale). A training row is kept only if its target week is at or before week 52, the last week of the development period. Development launches whose targets run past week 52 are therefore dropped from fitting, not just from evaluation. This stops calendar information from the test period, such as the Christmas 2010 level, from reaching the test forecasts through the week-of-year term. The leakage test in `src/` also checks that no fitted object contains a row with target week above 52.
4. Development set is used to pick: analog weighting, K, and the priors for the Bayesian model. The burn-in and launch definitions are fixed at the values in section 3. The test set is evaluated once per frozen configuration.
5. Freeze: before the test evaluation, the configuration files and code are committed to git. The commit hash is written to `results/PROTOCOL_LOCK.txt`. Any change after that point is labelled as a post-hoc change in the README. The protocol in this section should be committed before results exist (see section 9), so its date can be checked against git history.
6. Primary metric: WAPE at k = 4, pooled over h = 1 to 4, for M4 against M0 and M3. Primary decision rule: M4 counts as better at cold start if its WAPE is at least 3 percentage points lower than the better of M0 and M3, and the product-clustered 95% bootstrap interval for the difference excludes zero.
7. Secondary metrics: the full cold-start curve, interval coverage at 80% and 50%, interval score, and the real known-truth benchmark.
8. Seed: 20261029 for all random steps. Stan seed is set the same way.

## 6. Failure criteria (decided now)

The project is reported as a failure, or a partial failure, if any of these occur. Each is reported in the README with its numbers.

- F1. M4 does not beat the better of M0 and M3 at k = 4 by 3 or more WAPE points with a confidence interval excluding zero. Report: partial pooling gave no measurable cold-start gain on this data.
- F2. The analog-only prior (M5) is not better than a global-average prior at k = 4. Report: analog matching does not carry information on this data.
- F3. Posterior tau is indistinguishable from zero. Report: the hierarchical structure does not help beyond a global model here.
- F4. 80% intervals after conformal recalibration have test coverage outside 0.72 to 0.88. Report: intervals are not calibrated, even after recalibration.
- F5. The sign or the ranking of M4 against M0 and M3 changes in any robustness variant. Report: the result is fragile.
- F6. Fewer than 500 test launches have k = 12 weeks of history and 4 weeks of targets. Report: the sample is too small for the k = 12 point, and that point is not interpreted.
- F7. Bayesian convergence fails (R-hat >= 1.01 or divergent transitions). Report that M4 failed to fit, and give the empirical Bayes result as a separate, clearly labelled row.

Any of F1 to F7 is a legitimate result. The README must not describe a failed criterion as a success.

## 7. Why this is hard to reproduce in a day

The data is real retail data, which is messy in ways that take time to handle. Service codes, cancellations, returns and invoice quirks all have to be classified and documented, and each choice moves the launch count. Launch detection depends on a burn-in rule, because a product can look new when it was only absent from the early data. Getting the origin-based test right takes care: every feature must be recomputed from data that existed at that week, and the leakage test has to be written and passed. The hierarchical model needs a Bayesian fit with convergence checks, a prior built from text and price similarity, and a conformal step, and each of these has its own failure modes. The robustness grid repeats the whole pipeline over about ten variants, and the failure criteria must be applied honestly to each. Writing the plain-English explanation for each step, and a limitations section that is accurate for a two-year single-retailer sample, adds more work. Doing all of this carefully, with a protocol that was locked before results were seen, is weeks of work, not a day.

## 8. Repository layout

```
new-product-demand-partial-pooling/
  DESIGN.md                 (this file)
  README.md                 (question, data, method, results, limits, what failed; written last)
  data/
    download.R              (fetches the zip into data/raw/, checks size and sheet names)
    raw/                    (gitignored, never committed)
    processed/              (only if under 5 MB)
  src/
    01_clean_and_launches.R (component A)
    02_features_analogs.R   (component C, with leakage test)
    03_models_baselines.R   (M0 to M3, M5)
    04_model_partial_pool.R (M4, cmdstanr or glmmTMB)
    05_cold_start_eval.R    (component B and metrics)
    06_calibration.R        (component E)
    07_robustness.R         (component F)
    08_simulation_check.R   (component G, labelled)
    09_figures.R            (ggplot2 figures, final output in R)
  results/
    PROTOCOL_LOCK.txt
    *.csv                   (all numbers in the README come from these files)
  figures/
```

Tooling: R. Installed packages to add: readxl, data.table, MASS, glmmTMB, cmdstanr (if the Stan toolchain is available), ggplot2. Current local check: readxl is not installed, data.table is installed. Python is used only for a one-off xlsx row count during design and is not part of the project.

## 9. Commit and publication rules

- Public repo under jessieyang22 on GitHub. Push once results and the README exist. Before any test-set evaluation, DESIGN.md and the configuration files should be committed locally (git init in the project folder), which timestamps the protocol. Nothing was committed at design time, and the GitHub remote is not created at this step.
- Commit messages end with `Co-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>`.
- No raw data committed. No claim in the README without a matching CSV in `results/`.
- No analogies or metaphors in the README or any prose. Every step is explained in plain English.
