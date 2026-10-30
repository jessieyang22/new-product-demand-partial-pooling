# data/download.R
#
# Fetches the Online Retail II dataset (UCI ML Repository, dataset 502, CC BY 4.0)
# into data/raw/, checks the file size, computes its SHA-256, unzips it into a
# fresh folder, and checks the two sheet names.
#
# Run from the project root:
#   Rscript data/download.R
#
# Nothing in data/raw/ is committed (see .gitignore).

URL          <- "https://archive.ics.uci.edu/static/public/502/online+retail+ii.zip"
EXPECTED_ZIP_BYTES <- 45622418
EXPECTED_XLSX_BYTES <- 45622278
EXPECTED_SHEETS <- c("Year 2009-2010", "Year 2010-2011")

raw_dir     <- file.path("data", "raw")
zip_path    <- file.path(raw_dir, "online_retail_II.zip")
extract_dir <- file.path(raw_dir, "extracted")
xlsx_path   <- file.path(extract_dir, "online_retail_II.xlsx")
hash_file   <- file.path(raw_dir, "online_retail_II.zip.sha256")

dir.create(raw_dir, recursive = TRUE, showWarnings = FALSE)

# SHA-256 via the macOS/Linux `shasum` command, so no extra R package is needed.
sha256 <- function(path) {
  out <- system2("shasum", c("-a", "256", shQuote(path)), stdout = TRUE)
  strsplit(out[1], " +")[[1]][1]
}

# 1. Download (skipped when a file of the expected size is already cached)
if (!file.exists(zip_path) || file.size(zip_path) != EXPECTED_ZIP_BYTES) {
  message("Downloading ", URL)
  status <- system2("curl", c("-sL", "--fail", "-o", shQuote(zip_path), shQuote(URL)))
  if (status != 0) stop("curl failed with status ", status)
} else {
  message("Using cached zip: ", zip_path)
}

# 2. Size check
zip_bytes <- file.size(zip_path)
message("Zip size (bytes): ", zip_bytes)
if (zip_bytes != EXPECTED_ZIP_BYTES) {
  stop("Zip size ", zip_bytes, " does not match expected ", EXPECTED_ZIP_BYTES,
       ". The dataset may have changed; update DATA.md before continuing.")
}

# 3. Checksum (recorded, so later runs can detect a changed file)
zip_hash <- sha256(zip_path)
writeLines(c(paste(zip_hash, basename(zip_path))), hash_file)
message("SHA-256 zip: ", zip_hash)

# 4. Unzip into a fresh, empty folder (downloaded archives are untrusted)
if (dir.exists(extract_dir)) unlink(extract_dir, recursive = TRUE)
dir.create(extract_dir, recursive = TRUE)
listing <- unzip(zip_path, list = TRUE)
message("Archive contents:")
print(listing)
if (nrow(listing) != 1 || listing$Name[1] != "online_retail_II.xlsx") {
  stop("Unexpected archive contents: ", paste(listing$Name, collapse = ", "))
}
unzip(zip_path, files = "online_retail_II.xlsx", exdir = extract_dir)

xlsx_bytes <- file.size(xlsx_path)
message("xlsx size (bytes): ", xlsx_bytes)
if (xlsx_bytes != EXPECTED_XLSX_BYTES) {
  stop("xlsx size ", xlsx_bytes, " does not match expected ", EXPECTED_XLSX_BYTES)
}
message("SHA-256 xlsx: ", sha256(xlsx_path))

# 5. Sheet names (read from the workbook index, without loading the data)
sheets <- readxl::excel_sheets(xlsx_path)
message("Sheets: ", paste(sheets, collapse = " | "))
if (!identical(sheets, EXPECTED_SHEETS)) {
  stop("Sheet names differ from expected: ", paste(sheets, collapse = " | "))
}

message("Download and checks passed.")
message("Sheet names confirmed: ", paste(sheets, collapse = " | "))
