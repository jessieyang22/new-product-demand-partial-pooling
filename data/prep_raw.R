# data/prep_raw.R
#
# Reads both sheets of online_retail_II.xlsx with explicit column types,
# applies the sheet-overlap rule from DESIGN.md section 3 (rule 0), drops rows
# outside the study window, and profiles the raw data.
#
# Outputs
#   data/interim/lines_combined.rds   line-level table after the overlap rule
#                                     (gitignored; rebuilt by this script)
#   data/summary/*.csv                small summary tables (committed)
#   data/summary/prep_log.txt         the printed log of this run (committed)
#
# Run from the project root:
#   Rscript data/prep_raw.R
#
# Cleaning rules that DROP lines (product-code filter, price, cancellations)
# are applied in component A (src/01_clean_and_launches.R), not here. This
# script only counts what those rules would act on, so the counts in DATA.md
# come from code.

suppressPackageStartupMessages({
  library(readxl)
  library(data.table)
})

XLSX <- file.path("data", "raw", "extracted", "online_retail_II.xlsx")
SHEETS <- c("Year 2009-2010", "Year 2010-2011")
EXPECTED_HEADER <- c("Invoice", "StockCode", "Description", "Quantity",
                     "InvoiceDate", "Price", "Customer ID", "Country")
# Column types are set explicitly so readxl does not guess from the first rows.
# InvoiceDate is read as "date". readxl returns it as POSIXct with the stored
# wall-clock value labelled UTC, so no daylight-saving shift is applied.
# (Reading it as "numeric" triggers one R warning per cell, which made the
# read take many minutes, so it is not used.)
COL_TYPES <- c("text", "text", "text", "numeric", "date",
               "numeric", "numeric", "text")
OVERLAP_START <- as.Date("2010-12-01")
OVERLAP_END   <- as.Date("2010-12-09")
OVERLAP_EXPECTED <- 22523
WINDOW_START <- as.Date("2009-12-01")
WINDOW_END   <- as.Date("2011-12-09")
SUMMARY_DIR <- file.path("data", "summary")
INTERIM_DIR <- file.path("data", "interim")
dir.create(SUMMARY_DIR, recursive = TRUE, showWarnings = FALSE)
dir.create(INTERIM_DIR, recursive = TRUE, showWarnings = FALSE)

log_lines <- character()
log <- function(...) {
  msg <- paste0(...)
  message(msg)
  log_lines <<- c(log_lines, msg)
}
# print() output goes to stdout, not to the log. This sends the printed table
# to both the console and the saved log.
log_print <- function(x) {
  out <- capture.output(print(x))
  for (l in out) log(l)
}

# Calendar date of each line, taken in UTC from the stored timestamp.
# Lines with a missing or unreadable InvoiceDate get NA and are reported.
to_calendar_date <- function(ts) as.Date(ts, tz = "UTC")

read_sheet <- function(sheet) {
  warn_msgs <- character()
  dt <- withCallingHandlers(
    read_excel(XLSX, sheet = sheet, col_types = COL_TYPES, na = c("", "NA")),
    warning = function(w) {
      warn_msgs <<- c(warn_msgs, conditionMessage(w))
      invokeRestart("muffleWarning")
    }
  )
  dt <- as.data.table(dt)
  if (!identical(names(dt), EXPECTED_HEADER)) {
    stop("Header mismatch in sheet ", sheet, ": ", paste(names(dt), collapse = ", "))
  }
  if (length(warn_msgs) > 0) {
    log("readxl warnings for '", sheet, "': ", length(warn_msgs),
        " (first: ", warn_msgs[1], ")")
  } else {
    log("readxl warnings for '", sheet, "': 0")
  }
  dt[, sheet_row := .I + 1L]   # +1 for the header row, so this is the Excel row number
  dt[, sheet := sheet]
  dt[, inv_date := to_calendar_date(InvoiceDate)]
  dt
}

log("== prep_raw.R run at ", format(Sys.time(), tz = "UTC", usetz = TRUE))
log("File: ", XLSX)
raw <- lapply(SHEETS, read_sheet)
names(raw) <- SHEETS

# ---- 1. Raw profile per sheet -------------------------------------------------
profile_rows <- list()
for (s in SHEETS) {
  d <- raw[[s]]
  log("")
  log("== Sheet '", s, "'")
  log("Data rows (excluding header): ", nrow(d))
  log("Excel rows including header:  ", nrow(d) + 1)
  fully_empty <- sum(rowSums(!is.na(d[, EXPECTED_HEADER, with = FALSE])) == 0)
  log("Fully empty rows: ", fully_empty)
  dates <- d$inv_date[!is.na(d$inv_date)]
  log("Date range (valid dates, calendar day): ", as.character(min(dates)),
      " to ", as.character(max(dates)))
  log("Timestamp range (UTC): ", format(min(d$InvoiceDate, na.rm = TRUE), tz = "UTC"),
      " to ", format(max(d$InvoiceDate, na.rm = TRUE), tz = "UTC"))
  log("Missing or unreadable InvoiceDate: ", sum(is.na(d$InvoiceDate)))
  for (col in EXPECTED_HEADER) {
    v <- d[[col]]
    n_na <- sum(is.na(v))
    n_blank <- if (is.character(v)) sum(!is.na(v) & trimws(v) == "") else 0L
    profile_rows[[length(profile_rows) + 1]] <- data.table(
      sheet = s, column = col, type = class(v)[1], rows = nrow(d),
      n_na = n_na, share_na = round(n_na / nrow(d), 6),
      n_blank_text = n_blank, n_distinct = uniqueN(v[!is.na(v)])
    )
  }
  log("NA counts: ", paste(sprintf("%s=%d", EXPECTED_HEADER,
                                   sapply(EXPECTED_HEADER, function(c) sum(is.na(d[[c]])))),
                           collapse = ", "))
}
profile <- rbindlist(profile_rows)
fwrite(profile, file.path(SUMMARY_DIR, "raw_column_profile.csv"))

# Row counts and date ranges per sheet (also written to CSV)
sheet_summary <- rbindlist(lapply(SHEETS, function(s) {
  d <- raw[[s]]
  dates <- d$inv_date[!is.na(d$inv_date)]
  data.table(sheet = s, data_rows = nrow(d), excel_rows_with_header = nrow(d) + 1,
             min_date = as.character(min(dates)), max_date = as.character(max(dates)),
             missing_date_rows = sum(is.na(d$inv_date)))
}))
fwrite(sheet_summary, file.path(SUMMARY_DIR, "sheet_summary.csv"))

# ---- 2. Overlap check (DESIGN.md section 3, rule 0) --------------------------
s1 <- raw[[SHEETS[1]]]
s2 <- raw[[SHEETS[2]]]
in_overlap <- function(d) !is.na(d$inv_date) & d$inv_date >= OVERLAP_START & d$inv_date <= OVERLAP_END
ov1 <- s1[in_overlap(s1)]
ov2 <- s2[in_overlap(s2)]
log("")
log("== Overlap check, ", format(OVERLAP_START), " to ", format(OVERLAP_END))
log("Lines in sheet 1: ", nrow(ov1), "  (expected ", OVERLAP_EXPECTED, ")")
log("Lines in sheet 2: ", nrow(ov2), "  (expected ", OVERLAP_EXPECTED, ")")
if (nrow(ov1) != OVERLAP_EXPECTED || nrow(ov2) != OVERLAP_EXPECTED) {
  stop("Overlap line counts do not match the design (", OVERLAP_EXPECTED, ").")
}
row_key <- function(d) {
  k <- do.call(paste, c(lapply(EXPECTED_HEADER, function(c) as.character(d[[c]])), sep = "|"))
  sort(k)
}
same_content <- identical(row_key(ov1), row_key(ov2))
log("Overlap rows identical after sorting (all 8 columns, excluding row numbers): ", same_content)
if (!same_content) stop("Overlap rows differ between sheets. Stop and review before continuing.")

# Lines in sheet 2 before the overlap start, and in sheet 1 on or after 1 Dec 2010
s2_before <- sum(!is.na(s2$inv_date) & s2$inv_date < OVERLAP_START)
s1_after  <- sum(!is.na(s1$inv_date) & s1$inv_date >= OVERLAP_START)
log("Sheet 2 lines dated before 1 Dec 2010 (valid dates): ", s2_before)
log("Sheet 1 lines dated on or after 1 Dec 2010 (valid dates): ", s1_after)

# ---- 3. Combine with the rule from DESIGN.md section 3, rule 0 ----------------
# Sheet 1 for dates before 1 Dec 2010, sheet 2 for dates from 1 Dec 2010 onward.
# Then the window filter (1 Dec 2009 to 9 Dec 2011) drops the malformed 1899 rows.
part1 <- s1[!is.na(inv_date) & inv_date < OVERLAP_START]
part2 <- s2[!is.na(inv_date) & inv_date >= OVERLAP_START]
combined <- rbindlist(list(part1, part2), use.names = TRUE)
n_before_window <- nrow(combined)
combined <- combined[inv_date >= WINDOW_START & inv_date <= WINDOW_END]
log("")
log("== Combined table")
log("Rows from sheet 1 (before 1 Dec 2010): ", nrow(part1))
log("Rows from sheet 2 (from 1 Dec 2010):   ", nrow(part2))
log("Rows after overlap rule:               ", n_before_window)
log("Rows dropped by window filter:         ", n_before_window - nrow(combined))
log("Rows kept (window ", format(WINDOW_START), " to ", format(WINDOW_END), "): ", nrow(combined))
log("Combined date range: ", as.character(min(combined$inv_date)), " to ",
    as.character(max(combined$inv_date)))
log("Lines per calendar year-month (combined):")
ym <- combined[, .N, by = format(inv_date, "%Y-%m")][order(format)]
for (i in seq_len(nrow(ym))) log("  ", ym$format[i], ": ", ym$N[i])
fwrite(ym[, .(year_month = format, rows = N)], file.path(SUMMARY_DIR, "rows_by_month_combined.csv"))

# The timestamp is kept in UTC exactly as stored (no daylight-saving shift).
setnames(combined, "InvoiceDate", "invoice_datetime_utc")
combined[, source_sheet := sheet]
combined[, sheet := NULL]
setcolorder(combined, c("source_sheet", "sheet_row", "Invoice", "StockCode", "Description", "Quantity",
                         "invoice_datetime_utc", "Price", "Customer ID", "Country", "inv_date"))
saveRDS(combined, file.path(INTERIM_DIR, "lines_combined.rds"))
log("Saved: ", file.path(INTERIM_DIR, "lines_combined.rds"))

# ---- 4. Counts the cleaning rules will act on (not applied here) --------------
cn <- combined
cn[, inv_chr := substr(Invoice, 1, 1)]
cn[, is_cancel := startsWith(Invoice, "C")]
cn[, inv_is_numeric := grepl("^[0-9]+$", Invoice)]
cn[, code_ok := grepl("^[0-9]{5}[A-Za-z]*$", StockCode)]
cn[, price_bad := !is.na(Price) & Price <= 0]
cn[, qty_bad_sale := !is_cancel & !is.na(Quantity) & Quantity <= 0]
cn[, qty_pos_cancel := is_cancel & !is.na(Quantity) & Quantity > 0]

rule_counts <- data.table(
  check = c("total lines",
            "invoice starts with C (cancellation)",
            "invoice starts with letter A (adjustment) or other non-digit prefix, not C",
            "invoice is all digits",
            "StockCode missing",
            "StockCode fails 5-digit regex ^[0-9]{5}[A-Za-z]*$ (including missing)",
            "StockCode passes regex",
            "Price <= 0",
            "Quantity <= 0 on non-cancellation lines",
            "Quantity > 0 on cancellation lines",
            "Customer ID missing",
            "Description missing",
            "Description blank or missing",
            "Country missing"),
  count = c(nrow(cn),
            sum(cn$is_cancel),
            sum(!cn$is_cancel & !cn$inv_is_numeric),
            sum(cn$inv_is_numeric),
            sum(is.na(cn$StockCode)),
            sum(is.na(cn$StockCode) | !cn$code_ok),
            sum(!is.na(cn$StockCode) & cn$code_ok),
            sum(cn$price_bad),
            sum(cn$qty_bad_sale),
            sum(cn$qty_pos_cancel),
            sum(is.na(cn$`Customer ID`)),
            sum(is.na(cn$Description)),
            sum(is.na(cn$Description) | trimws(cn$Description) == ""),
            sum(is.na(cn$Country)))
)
rule_counts[, share := round(count / nrow(cn), 6)]
log("")
log("== Counts the cleaning rules act on (combined table, nothing dropped here)")
for (i in seq_len(nrow(rule_counts))) {
  log(sprintf("%-80s %10d  (%.4f%%)", rule_counts$check[i], rule_counts$count[i],
              100 * rule_counts$share[i]))
}
fwrite(rule_counts, file.path(SUMMARY_DIR, "cleaning_rule_counts.csv"))

# Invoice prefixes that are not digits and not C
odd_prefix <- cn[!is_cancel & !inv_is_numeric, .(lines = .N, distinct_invoices = uniqueN(Invoice),
                                                 example_invoice = Invoice[1]),
                 by = inv_chr][order(-lines)]
log("")
log("Non-digit, non-C invoice prefixes:")
if (nrow(odd_prefix) == 0) log("  none") else log_print(odd_prefix)
fwrite(odd_prefix, file.path(SUMMARY_DIR, "invoice_prefix_non_numeric_non_cancel.csv"))

# Non-product StockCodes (regex failures), largest first
bad_codes <- cn[is.na(StockCode) | !code_ok,
                .(lines = .N, distinct_descriptions = uniqueN(Description),
                  example_description = Description[which(!is.na(Description))[1]],
                  sum_quantity = sum(Quantity, na.rm = TRUE),
                  sum_revenue = round(sum(Quantity * Price, na.rm = TRUE), 2)),
                by = .(StockCode)][order(-lines)]
fwrite(bad_codes, file.path(SUMMARY_DIR, "stockcode_regex_failures.csv"))
log("")
log("StockCodes failing the regex: ", nrow(bad_codes), " distinct values")
log("Top 25 by line count:")
log_print(head(bad_codes[, .(StockCode = ifelse(is.na(StockCode), "<NA>", StockCode), lines,
                          example_description, sum_quantity, sum_revenue)], 25))

# Distinct counts
log("")
log("Distinct StockCode (all, non-missing):             ", uniqueN(cn$StockCode[!is.na(cn$StockCode)]))
log("Distinct StockCode passing regex:                  ", uniqueN(cn$StockCode[!is.na(cn$StockCode) & cn$code_ok]))
log("Distinct Invoice:                                  ", uniqueN(cn$Invoice))
log("Distinct Customer ID (non-missing):                ", uniqueN(cn$`Customer ID`[!is.na(cn$`Customer ID`)]))
log("Distinct Country:                                  ", uniqueN(cn$Country[!is.na(cn$Country)]))

# Numeric ranges (observed)
rng <- data.table(
  column = c("Quantity", "Price", "Customer ID"),
  min = c(min(cn$Quantity, na.rm = TRUE), min(cn$Price, na.rm = TRUE), min(cn$`Customer ID`, na.rm = TRUE)),
  p50 = c(median(cn$Quantity, na.rm = TRUE), median(cn$Price, na.rm = TRUE), median(cn$`Customer ID`, na.rm = TRUE)),
  max = c(max(cn$Quantity, na.rm = TRUE), max(cn$Price, na.rm = TRUE), max(cn$`Customer ID`, na.rm = TRUE))
)
fwrite(rng, file.path(SUMMARY_DIR, "numeric_ranges_combined.csv"))
log("")
log("Numeric ranges (combined):")
log_print(rng)

# Country counts
ctry <- cn[, .(lines = .N), by = Country][order(-lines)]
fwrite(ctry, file.path(SUMMARY_DIR, "country_counts.csv"))
log("Share of lines with Country == United Kingdom: ",
    round(100 * mean(cn$Country == "United Kingdom", na.rm = TRUE), 2), "%")

# Failing StockCodes grouped by visible pattern, so the cleaning decision is visible.
# These are counts only. The rule itself (5 digits) is applied in component A.
bad_cat <- bad_codes[, .(
  category = fifelse(is.na(StockCode), "missing",
             fifelse(grepl("^DCGS", StockCode), "DCGS prefix (dotcom product-like codes)",
             fifelse(grepl("^gift_", StockCode), "gift_ prefix (gift vouchers)",
             fifelse(grepl("^[A-Za-z]+$", StockCode), "letters only (service/adjustment codes)",
                     "other")))),
  StockCode, lines, sum_revenue)][, .(distinct_codes = .N, lines = sum(lines),
                                      sum_revenue = round(sum(sum_revenue), 2)),
                                  by = category][order(-lines)]
fwrite(bad_cat, file.path(SUMMARY_DIR, "stockcode_regex_failures_by_category.csv"))
log("")
log("StockCodes failing the regex, by category:")
for (i in seq_len(nrow(bad_cat))) {
  log(sprintf("  %-50s codes=%3d lines=%6d revenue=%12.2f", bad_cat$category[i],
              bad_cat$distinct_codes[i], bad_cat$lines[i], bad_cat$sum_revenue[i]))
}
# Distinct product-like codes that the DCGS prefix would add back (for the README)
log("Distinct DCGS-prefixed StockCodes: ", sum(grepl("^DCGS", unique(cn$StockCode))))

# Numeric ranges, written to the log too
log("")
log("Numeric ranges (combined):")
for (i in seq_len(nrow(rng))) {
  log(sprintf("  %-12s min=%s median=%s max=%s", rng$column[i], format(rng$min[i]),
              format(rng$p50[i]), format(rng$max[i])))
}

writeLines(log_lines, file.path(SUMMARY_DIR, "prep_log.txt"))
message("Done. Log written to ", file.path(SUMMARY_DIR, "prep_log.txt"))
