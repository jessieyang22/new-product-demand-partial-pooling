# DATA.md: Online Retail II (UCI dataset 502)

This file records what was actually observed in the data. Every number here
comes from a script in this repository and a file in `data/summary/`. Where a
number is not in a CSV, the script that produced it is named.

## 1. Source and license

- Dataset: Online Retail II, UCI Machine Learning Repository, dataset 502.
- Page: https://archive.ics.uci.edu/dataset/502/online+retail+ii
- Direct file: https://archive.ics.uci.edu/static/public/502/online+retail+ii.zip
- License: Creative Commons Attribution 4.0 International (CC BY 4.0), as stated on the dataset page.
- Attribution (copied from the dataset page on 2026-10-29): Chen, D. (2012). Online Retail II [Dataset]. UCI Machine Learning Repository. https://doi.org/10.24432/C5CG6D. Creator: Daqing Chen. Donated 20 September 2019 (UCI page).

### Files and checksums (observed 2026-10-29)

| File | Size (bytes) | SHA-256 |
|---|---|---|
| `data/raw/online_retail_II.zip` | 45,622,418 | `572e36277c2390fbfde10664750731e0a86f55e33470d91919085f0408e67bfb` |
| `data/raw/extracted/online_retail_II.xlsx` | 45,622,278 | `bcbe73b35f5b7babf197fb0cb983a11f5d9ff929078d4aa53d171b1f2df2e980` |

The zip contains one file, `online_retail_II.xlsx`. Both files are above the
5 MB limit in DESIGN.md section 2, so they are never committed. They sit in
`data/raw/`, which is in `.gitignore`.

## 2. How to reproduce

Run these from the project folder, in this order:

```
Rscript data/download.R        # fetches the zip if missing, checks size, hash and sheet names
Rscript data/prep_raw.R        # reads both sheets, applies the sheet-overlap rule, writes summaries
Rscript data/feasibility_check.R   # rough launch counts used for failure criterion F6
```

Packages needed: `readxl`, `data.table`. The download script uses the
system `shasum` command for the checksum, so it needs no extra R package.

What each step writes:

- `data/download.R` writes `data/raw/online_retail_II.zip`, `data/raw/online_retail_II.zip.sha256` and `data/raw/extracted/online_retail_II.xlsx`.
- `data/prep_raw.R` writes `data/interim/lines_combined.rds` (gitignored, 13.6 MB, rebuilt by the script) and the CSVs and log in `data/summary/`.
- `data/feasibility_check.R` writes `data/summary/feasibility_launch_counts.csv`.

Run history for this document: `download.R` was run once on the cached zip
(all checks passed). `prep_raw.R` was run end to end after a fix that sends
printed tables into the log (the earlier run had lost them). `feasibility_check.R`
was run twice, once before and once after adding two line-count rows. The
counts below come from the final run.

## 3. Structure of the raw file

- Two sheets: `Year 2009-2010` and `Year 2010-2011`.
- Each sheet has a header row and then data rows. Excel row numbers include the header.
- Column E (`InvoiceDate`) was checked in the raw sheet XML, not only through readxl. Every value is a number (an Excel date serial). The smallest serial is 40148.32 in sheet 1 and 40513.35 in sheet 2. No value is below 1000, so no 1899 dates exist. See section 9 for the correction to DESIGN.md.

| Sheet | Data rows (excl. header) | Excel rows incl. header | First date | Last date | Rows with missing date |
|---|---|---|---|---|---|
| Year 2009-2010 | 525,461 | 525,462 | 2009-12-01 | 2010-12-09 | 0 |
| Year 2010-2011 | 541,910 | 541,911 | 2010-12-01 | 2011-12-09 | 0 |

Source: `data/summary/sheet_summary.csv`, `data/summary/prep_log.txt`, and the XML check in section 9.

Both sheets hold a copy of 9 December 2010 and the days before it are in sheet 1 only, so the overlap needs a rule (section 4).

## 4. Sheet-overlap rule (DESIGN.md section 3, rule 0)

- Lines dated 1 to 9 December 2010 in sheet 1: 22,523.
- Lines dated 1 to 9 December 2010 in sheet 2: 22,523.
- The two sets are identical after sorting, on all 8 raw columns (`prep_raw.R` compares them with `identical()`, and the check passed).
- Sheet 2 has no lines dated before 1 December 2010. Sheet 1 has 22,523 lines dated on or after 1 December 2010, which are the same 9 days.

Rule applied: take sheet 1 for dates before 1 December 2010, and sheet 2 from 1 December 2010 onward.

| Step | Lines |
|---|---|
| Sheet 1, dates before 1 Dec 2010 | 502,938 |
| Sheet 2, dates from 1 Dec 2010 | 541,910 |
| Combined after the overlap rule | 1,044,848 |
| Dropped by the window filter (1 Dec 2009 to 9 Dec 2011) | 0 |
| **Rows kept** | **1,044,848** |

Note: the raw total is 1,067,371 lines (525,461 + 541,910). The combined table has 1,044,848. DESIGN.md's "about 1.07 million" describes the raw total.

Combined date range: 2009-12-01 to 2011-12-09.

Lines per calendar month are in `data/summary/rows_by_month_combined.csv`. The busiest months are November 2010 (78,015) and November 2011 (84,711). December 2011 has 25,526 lines because the data stops on 9 December.

## 5. Data dictionary

The first eight columns are the raw columns. The last four are derived by `prep_raw.R`.

| Column | Type in R | Meaning | Observed NA, sheet 1 (raw) | Observed NA, sheet 2 (raw) | Observed NA, combined |
|---|---|---|---|---|---|
| `Invoice` | character | Invoice number. A leading `C` marks a cancellation. Six lines start with `A` (adjustments). | 0 (0.00%) | 0 (0.00%) | 0 |
| `StockCode` | character | The retailer's product or service code. Product codes are 5 digits, sometimes with letters after them. Service codes (for example `POST`, `M`, `D`, `BANK CHARGES`) are not products. | 0 | 0 | 0 |
| `Description` | character | Product name as typed on the invoice line. | 2,928 (0.56%) | 1,454 (0.27%) | 4,275 (0.41%) |
| `Quantity` | numeric | Units on the line. Negative on cancellations and some adjustments. | 0 | 0 | 0 |
| `InvoiceDate` | date-time | Time of the line, stored in the file without a time zone. `prep_raw.R` keeps it unchanged. | 0 | 0 | 0 |
| `Price` | numeric | Unit price in pounds sterling. Zero or negative on some lines. | 0 | 0 | 0 |
| `Customer ID` | numeric | Customer number. Missing for about a fifth to a quarter of lines. | 107,927 (20.54%) | 135,080 (24.93%) | 235,287 (22.52%) |
| `Country` | character | Customer's country. 43 distinct values. 91.88% of lines are United Kingdom. | 0 | 0 | 0 |
| `source_sheet` | character | Which sheet the line came from (after the overlap rule). | n/a | n/a | n/a |
| `sheet_row` | integer | Excel row number in the source sheet (header is row 1). | n/a | n/a | n/a |
| `invoice_datetime_utc` | date-time | Same as `InvoiceDate`, renamed. Stored as a clock time with the label UTC. | n/a | n/a | n/a |
| `inv_date` | Date | Calendar date of the line, taken from `InvoiceDate`. Used for weekly grouping. | n/a | n/a | 0 |

Raw NA counts come from `data/summary/raw_column_profile.csv`. The combined column is the sum after the overlap rule, from `prep_log.txt` and `cleaning_rule_counts.csv`. Customer ID is missing for 22.52% of the combined lines, so any analysis that keys on Customer ID drops a large share of lines.

Numeric ranges (combined, from `data/summary/numeric_ranges_combined.csv`):

| Column | Min | Median | Max |
|---|---|---|---|
| Quantity | -80,995 | 3 | 80,995 |
| Price | -53,594.36 | 2.10 | 38,970 |
| Customer ID | 12,346 | 15,248 | 18,287 |

The extreme Quantity and Price values are real lines in the file. They are not cleaned in this step. Component A applies the rules in DESIGN.md section 3.

## 6. Cleaning-rule counts (observed, nothing dropped yet)

From `data/summary/cleaning_rule_counts.csv`. These counts apply to the combined table of 1,044,848 lines. Each rule is counted, not applied.

| Check | Lines | Share |
|---|---|---|
| Invoice starts with `C` (cancellation) | 19,165 | 1.83% |
| Invoice starts with a letter other than `C` (the `A` adjustment lines) | 6 | 0.0006% |
| StockCode missing | 0 | 0% |
| StockCode fails the rule `^[0-9]{5}[A-Za-z]*$` | 5,992 | 0.57% |
| StockCode passes the rule | 1,038,856 | 99.43% |
| Price <= 0 | 6,029 | 0.58% |
| Quantity <= 0 on a sales line (not a cancellation) | 3,393 | 0.32% |
| Quantity > 0 on a cancellation line | 1 | 0.0001% |
| Description missing | 4,275 | 0.41% |

Lines that fail the StockCode rule, by group (`data/summary/stockcode_regex_failures_by_category.csv`):

| Group | Distinct codes | Lines | Revenue (Quantity x Price, currency as stored in the file, believed to be pounds sterling) |
|---|---|---|---|
| Letters only (service and adjustment codes such as `POST`, `DOT`, `M`, `D`, `BANK CHARGES`) | 12 | 5,334 | -51,810.89 |
| Other (for example `ADJUST`, `AMAZONFEE`) | 7 | 401 | -21,396.95 |
| `DCGS` prefix (dotcom product-like codes) | 34 | 157 | 1,154.72 |
| `gift_` prefix (gift vouchers) | 9 | 100 | 1,686.61 |

Total: 62 distinct codes fail the rule (`data/summary/stockcode_regex_failures.csv` lists each one with its line count).

**Decision for the owner of DESIGN.md.** The rule in DESIGN.md section 3, rule 1 (5 digits, optional letters) also drops the 34 `DCGS` codes. Some of these look like real products (for example `DCGS0058` is `MISO PRETTY GUM`). They are 157 lines, about 0.015% of the combined table. The design was written before this count existed. This file does not change the rule. If the `DCGS` codes should count as products, the rule must change before the results are produced, and the change must be written into DESIGN.md with a dated note.

Other counts in `data/summary/invoice_prefix_non_numeric_non_cancel.csv`: the six lines starting with `A` are all on invoice `A506401`.

Distinct counts in the combined table (`prep_log.txt`):

- StockCode, all non-missing values: 5,304. Passing the rule: 5,242.
- Invoice: 53,628.
- Customer ID, non-missing: 5,942.
- Country: 43.

## 7. Feasibility counts (rough, for the launch cohort)

From `data/summary/feasibility_launch_counts.csv`, written by `data/feasibility_check.R`. This is an estimate. The official counts come from component A, which applies the same rules.

| Item | Count |
|---|---|
| Lines in the combined table | 1,044,848 |
| Sales lines kept (product-like code, not a cancellation, Quantity > 0, Price > 0) | 1,014,945 |
| Product codes with any sales in the window | 4,877 |
| Launch candidates: no sales in burn-in weeks 1 to 8, and a sale later | 1,662 |
| Development launches: first sale in weeks 9 to 52 | 985 |
| Test launches: first sale in week 53 or later | 677 |
| Test launches with 12 weeks of history and 4 target weeks observed | 394 |
| Test launches with 4 weeks of history and 4 target weeks observed | 579 |

Week definition used here: Monday-start weeks, week 1 starts Monday 30 November 2009. The last full week is week 105, which starts 28 November 2011 and ends 4 December 2011. The partial week after it is dropped.

What this means for the study:

- Failure criterion F6 (DESIGN.md section 6) applies. Only 394 test launches have 12 weeks of history and 4 target weeks, which is below the 500 in DESIGN.md. The k = 12 point will be reported with that shortfall, and the README will not interpret it.
- At k = 4 there are 579 test launches with the full window. That is above 500, so the k = 4 comparison that the primary decision rule uses has enough launches.
- Development launches (985) are enough to fit and tune the models, as planned.
- Because the counts are rough, the exact numbers will shift slightly when component A applies its own code. The DESIGN.md criteria are applied to component A's counts.

## 8. Limits observed in the data

- One UK-based business-to-business wholesaler. 91.88% of lines are United Kingdom customers.
- About 22.5% of lines have no Customer ID.
- Some lines have negative or zero prices and quantities (sections 5 and 6). Under the DESIGN.md rules, these lines are not counted as demand. Component A applies those rules.
- Two years of data from 2009 to 2011. The results describe this retailer and period only.
- Product codes are the retailer's own codes, as DESIGN.md section 2 says.

## 9. Corrections to DESIGN.md (dated)

These corrections are recorded in DESIGN.md section 2 as dated notes. The original text is not changed.

- Date check (2026-10-29): the design said the InvoiceDate column has one value below serial 1000 (year 1899) in each sheet. A direct check of the raw sheet XML found none. Column E in sheet 1 has 525,461 numeric values, all from 40,148.32 to 40,521.83. Sheet 2 has 541,910 numeric values, all from 40,513.35 to 40,886.53. The window filter drops 0 rows. The check was a Python script (`zipfile` plus a regex) run once on the cached xlsx, and its code is not in the repository because it is a one-off check, not part of the pipeline.
- Line counts: the raw total is 1,067,371 lines. After the overlap rule the combined table has 1,044,848 lines (see section 4).
