################################################################################
#
# Compares asset quality (NPL ratio), capitalisation (Total capital, Tier 1, CET1,
# Tier 2 over RWAs) and profitability (ROE, ROA, net interest income, NIM) of euro
# area banks by country and by macro-region.
#
# Input : BankFocus export "data/Export 2019 2023.xlsx" (licensed data, not included in the
#         repository; the script runs only where the export is available locally)
#         - "Results", "Results (20)" ... "Results (23)": balance sheet, one sheet per year
#         - "Results (2)": net income, equity, NII and total assets, all years side by side
#         - "Results (3)": net interest margin, all years side by side
# Output: output/cs1_country_metrics.csv, output/cs1_region_metrics.csv and 14 charts in
#         output/ - aggregates only, no bank-level data
#
# Data-quality choices (applied the same way to every metric):
#   1. Croatia (HR) is excluded: it adopted the euro only in 2023.
#   2. National central banks are excluded: they are in the BankFocus bank list but are
#      not part of the banking sector, and their size would distort country totals.
#   3. Statements with no financials (NF) or limited financials (LF) are excluded.
#   4. One statement per bank and year (bank = name + country), chosen by consolidation
#      code priority C1 > U1 > U2 > C2 > C* > U*, among statements that report the
#      variables needed for that metric. This avoids counting the same bank twice.
#   5. Each sheet is processed on its own. The exports list banks in a different order
#      in each sheet, so sheets are never combined by row position.
#   6. Balance-sheet indicators (loans, NPL, capital) use a balanced sample: only banks that
#      report them in all five years. Reporting of NPL and RWAs is not stable over time (German
#      banks reporting NPL fall from about 1,140 in 2019 to under 80 in 2021), so an unbalanced
#      sample would mix changes in the ratios with changes in which banks are observed.
#   7. Statistical confidentiality: a country value based on fewer than 3 banks is not shown
#      (it would reveal the figures of an individual bank).
################################################################################

suppressPackageStartupMessages({
  library(readxl)     # read the sheets of the BankFocus export
  library(dplyr)      # data manipulation (filter, mutate, joins, summarise)
  library(tidyr)      # pivot_longer / pivot_wider
  library(purrr)      # map / reduce over sheets, years and indicators
  library(ggplot2)    # ROE distribution charts
  library(scales)     # axis formats
  library(grDevices)  # png() and palette.colors()
})

# Folder of this script: data are read from <script folder>/data, results go to <script folder>/output.
# (With Rscript the path comes from --file; in RStudio, open the folder as working directory.)
script_dir <- function() {
  arg <- grep("^--file=", commandArgs(trailingOnly = FALSE), value = TRUE)
  if (length(arg) > 0) dirname(normalizePath(sub("^--file=", "", arg))) else getwd()
}
BASE_DIR  <- script_dir()
DATA_FILE <- file.path(BASE_DIR, "data", "Export 2019 2023.xlsx")
OUT_DIR   <- file.path(BASE_DIR, "output")

# The BankFocus export is licensed data and is not part of the repository
if (!file.exists(DATA_FILE)) {
  stop("BankFocus export not found at '", DATA_FILE, "'. The data are licensed and not ",
       "included in the repository; the executed notebook cs1_banking_metrics.ipynb shows ",
       "all the results.", call. = FALSE)
}

YEARS     <- 2019:2023
# Sheet of the export with the balance sheet of each year, named by year
YEARLY_SHEETS <- setNames(c("Results", "Results (20)", "Results (21)",
                            "Results (22)", "Results (23)"), YEARS)

# One statement per bank and year, chosen by this consolidation-code priority:
#   C1 consolidated, no unconsolidated companion  U1 unconsolidated, no consolidated companion
#   U2 unconsolidated, with a consolidated companion  C2 consolidated, with an unconsolidated one
#   C* / U* additional statements (e.g. a second accounting standard)
# NF (no financials) and LF (limited financials) are not in the list and are dropped.
CODE_PRIORITY <- c("C1", "U1", "U2", "C2", "C*", "U*")
# Croatia adopted the euro only in 2023
EXCLUDED_COUNTRIES <- c("HR")
# National central banks are in the BankFocus bank list but are not part of the banking sector
CENTRAL_BANKS <- c(
  "DEUTSCHE BUNDESBANK", "BANQUE DE FRANCE", "BANCA D'ITALIA", "BANCO DE ESPANA",
  "BANQUE CENTRALE DU LUXEMBOURG", "BANK OF GREECE", "BANCO DE PORTUGAL, EP",
  "CENTRAL BANK & FINANCIAL SERVICES AUTHORITY OF IRELAND",
  "SUOMEN PANKKI FINLANDS BANK", "NARODNA BANKA SLOVENSKA", "CENTRAL BANK OF CYPRUS",
  "LATVIJAS BANKA", "CENTRAL BANK OF MALTA", "NEDERLANDSCHE BANK NV (DE)"
)
# Macro-regions used in the presentation (country ISO codes)
REGIONS <- list(
  North  = c("EE", "FI", "IE", "NL"),
  Center = c("AT", "BE", "DE", "FR", "LU"),
  South  = c("CY", "ES", "GR", "IT", "MT", "PT"),
  East   = c("LT", "LV", "SI", "SK")
)
# Identifier columns of every sheet: bank name, country (ISO code), consolidation code
ID_COLS <- c("name", "country", "code")
# Statistical confidentiality: no published value may rest on fewer than 3 banks, otherwise a
# "country" figure would reveal the figures of an individual bank
MIN_BANKS <- 3


# ------------------------------------------------------------------------------
# Loading: every sheet becomes a long table with one row per statement and year
# ------------------------------------------------------------------------------
# read_sheet(sheet)
# Reads one sheet of the export ("n.a." becomes NA), drops the BankFocus row number and
# names the first three columns name, country and code. The other columns keep the long
# BankFocus names and are renamed by the loaders below.
read_sheet <- function(sheet) {
  df <- read_excel(DATA_FILE, sheet = sheet, na = "n.a.", .name_repair = "unique_quiet")
  df <- df[, -1]  # column 1 is only the row number of the export
  names(df)[1:3] <- ID_COLS
  df
}

# load_balance_sheet()
# Balance-sheet items from the five yearly sheets, stacked into one table with one row per
# statement and year. Each sheet is renamed on its own, so the different order of the banks
# in each sheet does not matter. Amounts in EUR thousands.
load_balance_sheet <- function() {
  vars <- c("total_assets", "net_loans", "npl", "total_capital", "tier1", "cet1",
            "tier2", "rwa")
  imap_dfr(YEARLY_SHEETS, function(sheet, year) {
    df <- read_sheet(sheet)[, 1:(3 + length(vars))]  # drops an empty trailing column in 2022
    names(df) <- c(ID_COLS, vars)
    mutate(df, year = as.integer(year))
  })
}

# load_profitability()
# "Results (2)" has all years side by side: after the 3 id columns come net income, equity and
# net interest income for 2019, then the same three for 2020, and so on (columns 4-18), then
# total assets for 2019-2023 (columns 19-23). For year i the columns are picked by position
# and one table per year is built; the five tables are stacked.
load_profitability <- function() {
  df <- read_sheet("Results (2)")
  map_dfr(seq_along(YEARS), function(i) {
    tibble(df[, ID_COLS],
           net_income   = df[[3 + 3 * (i - 1) + 1]],
           equity       = df[[3 + 3 * (i - 1) + 2]],
           nii          = df[[3 + 3 * (i - 1) + 3]],
           total_assets = df[[18 + i]],   # columns 19-23
           year         = YEARS[i])
  })
}

# load_nim()
# Net interest margin (%), one column per year (columns 4-8): turned into a long table, with
# the year read from the last four characters of the column name.
load_nim <- function() {
  df <- read_sheet("Results (3)")
  df %>%
    pivot_longer(cols = 4:8, names_to = "col", values_to = "nim") %>%
    mutate(year = as.integer(substr(col, nchar(col) - 3, nchar(col)))) %>%
    select(-col)
}


# ------------------------------------------------------------------------------
# Cleaning
# ------------------------------------------------------------------------------
# apply_sample_filters(df)
# Keeps euro area commercial banks with usable statements (choices 1-3): removes Croatia,
# the national central banks and the codes not in CODE_PRIORITY (NF, LF).
apply_sample_filters <- function(df) {
  df %>% filter(!country %in% EXCLUDED_COUNTRIES,
                !name %in% CENTRAL_BANKS,
                code %in% CODE_PRIORITY)
}

# one_statement_per_bank(df, required)   (choice 4)
# Among the statements that report all the `required` variables, keeps for each bank and
# year the one with the highest-priority consolidation code. A bank is identified by name
# AND country, since banks in different countries can have the same name. Filtering on the
# required variables first means that, if the C1 statement lacks them, the next statement
# of the same bank that has them is used.
one_statement_per_bank <- function(df, required) {
  df %>%
    filter(if_all(all_of(required), ~ !is.na(.x))) %>%   # all required variables reported
    mutate(rank = match(code, CODE_PRIORITY)) %>%        # 1 = C1, 2 = U1, ...
    arrange(rank) %>%
    distinct(name, country, year, .keep_all = TRUE) %>%  # first row = best code
    select(-rank)
}

# balanced_sample(df)   (choice 6)
# Keeps only the banks observed in all five years, so that changes over time are not
# changes in which banks are in the sample.
balanced_sample <- function(df) {
  df %>% group_by(name, country) %>% filter(n_distinct(year) == length(YEARS)) %>% ungroup()
}

# add_region(df): adds the macro-region of each bank's country
add_region <- function(df) {
  # Named vector country -> region, e.g. c(EE = "North", FI = "North", ..., SK = "East")
  lookup <- setNames(rep(names(REGIONS), lengths(REGIONS)), unlist(REGIONS))
  mutate(df, region = unname(lookup[country]))
}


# ------------------------------------------------------------------------------
# Aggregation: ratios are sum(numerator) / sum(denominator) over the same banks,
# i.e. volume-weighted; "EA" is the euro area total
# ------------------------------------------------------------------------------
# with_euro_area(df, f)
# Applies the summary function f (built with ratio(), total() or median_of() below) to each
# country and year, and to the whole euro area ("EA") in each year. Returns a long table
# (year, country, value). Country values based on fewer than MIN_BANKS banks are suppressed
# (set to NA); the euro area value always rests on many banks.
with_euro_area <- function(df, f) {
  bind_rows(
    # countries: pick(everything()) passes the rows of the group to f
    df %>% group_by(year, country) %>%
      summarise(value = f(pick(everything())), n_banks = n(), .groups = "drop") %>%
      mutate(value = if_else(n_banks < MIN_BANKS, NA_real_, value)) %>%
      select(-n_banks),
    # euro area: all banks of the year together
    df %>% group_by(year) %>% summarise(value = f(pick(everything())), .groups = "drop") %>%
      mutate(country = "EA")
  )
}
# Summary functions: each returns a function of the rows of one group
# volume-weighted ratio, e.g. ratio("npl", "net_loans") = total NPL / total net loans
ratio  <- function(num, den) function(d) sum(d[[num]]) / sum(d[[den]])
total  <- function(col) function(d) sum(d[[col]]) / 1e6   # EUR thousands -> EUR bn
median_of <- function(col) function(d) median(d[[col]])

# country_metrics(bs, prof, nim)
# All country and euro area indicators in one wide table (one row per year and country).
# Each indicator has its own sample: the banks that report the variables it needs (balanced
# over the five years for loans, NPL and capital), so a missing value for one indicator does
# not remove the bank from the others.
country_metrics <- function(bs, prof, nim) {
  npl <- balanced_sample(one_statement_per_bank(bs, c("net_loans", "npl")))
  cap <- balanced_sample(one_statement_per_bank(bs, c("total_capital", "tier1", "cet1", "tier2", "rwa")))
  roe <- one_statement_per_bank(prof, c("net_income", "equity"))
  roa <- one_statement_per_bank(prof, c("net_income", "total_assets"))
  nii <- one_statement_per_bank(prof, "nii")
  nim <- one_statement_per_bank(nim, "nim")

  list(
    net_loans_bn        = with_euro_area(npl, total("net_loans")),
    npl_bn              = with_euro_area(npl, total("npl")),
    npl_ratio           = with_euro_area(npl, ratio("npl", "net_loans")),
    total_capital_ratio = with_euro_area(cap, ratio("total_capital", "rwa")),
    tier1_ratio         = with_euro_area(cap, ratio("tier1", "rwa")),
    cet1_ratio          = with_euro_area(cap, ratio("cet1", "rwa")),
    tier2_ratio         = with_euro_area(cap, ratio("tier2", "rwa")),
    roe                 = with_euro_area(roe, ratio("net_income", "equity")),
    roa                 = with_euro_area(roa, ratio("net_income", "total_assets")),
    nii_bn              = with_euro_area(nii, total("nii")),
    # NIM is already a ratio for each bank, so it is summarised with the median
    nim_median          = with_euro_area(nim, median_of("nim"))
  ) %>%
    imap(~ rename(.x, !!.y := value)) %>%                # value -> name of the indicator
    reduce(full_join, by = c("year", "country")) %>%     # one column per indicator
    arrange(year, country)
}

# region_metrics(bs, prof)
# Indicators by macro-region and year: aggregate NPL ratio and total capital ratio
# (volume-weighted, balanced samples), and the distribution of ROE across banks (25th
# percentile, median, 75th percentile), which shows how different banks in the region are.
region_metrics <- function(bs, prof) {
  npl <- add_region(balanced_sample(one_statement_per_bank(bs, c("net_loans", "npl"))))
  cap <- add_region(balanced_sample(one_statement_per_bank(
    bs, c("total_capital", "tier1", "cet1", "tier2", "rwa"))))
  # Bank-level ROE distribution; banks with zero or negative equity are left out
  roe <- add_region(one_statement_per_bank(prof, c("net_income", "equity"))) %>%
    filter(equity > 0) %>%
    mutate(bank_roe = net_income / equity)

  list(
    npl %>% group_by(year, region) %>%
      summarise(npl_ratio = sum(npl) / sum(net_loans), .groups = "drop"),
    cap %>% group_by(year, region) %>%
      summarise(total_capital_ratio = sum(total_capital) / sum(rwa), .groups = "drop"),
    roe %>% group_by(year, region) %>%
      summarise(roe_p25 = quantile(bank_roe, 0.25), roe_median = median(bank_roe),
                roe_p75 = quantile(bank_roe, 0.75), n_banks_roe = n(), .groups = "drop")
  ) %>%
    reduce(full_join, by = c("year", "region")) %>%
    arrange(year, region)
}



# ------------------------------------------------------------------------------
# Charts: same design as the charts in the presentation (base R barplots and ggplot)
# ------------------------------------------------------------------------------
# Colours of the years, as in the presentation: 2019 teal, 2020 yellow, 2021 light blue,
# 2022 pink, 2023 navy
YEAR_COLOURS <- c(palette.colors(n = 1, "Set3"), "yellow", palette.colors(1, palette = "Paired"),
                  palette.colors(1, palette = "Pastel1"), "#000080")
REGION_NAMES <- c(North = "Northern", South = "Southern", Center = "Central", East = "Eastern")

# year_matrix(...)
# Matrix for barplot(beside = TRUE): rows = years, columns = countries in alphabetical
# order with the euro area last. scale = 100 turns ratios into %; include_ea = FALSE leaves
# out the euro area (for volumes, where it would dwarf the countries).
year_matrix <- function(countries, column, scale = 100, include_ea = TRUE) {
  wide <- countries %>%
    select(year, country, value = all_of(column)) %>%
    pivot_wider(names_from = country, values_from = value) %>%
    arrange(year)
  order <- c(sort(setdiff(names(wide)[-1], "EA")), if (include_ea) "EA")
  m <- as.matrix(wide[, order]) * scale
  rownames(m) <- wide$year
  m
}

# y-axis limits on "pretty" round values that include every bar, so no bar goes past the axis
nice_ylim <- function(...) range(pretty(c(0, na.omit(unlist(list(...))))))

# open_png(filename, height): opens a PNG file in output/ for the base R charts; the chart
# is written when dev.off() is called
open_png <- function(filename, height = 1750) {
  png(file.path(OUT_DIR, filename), width = 2860, height = height, res = 300, pointsize = 8)
}

# year_bars(...): grouped bars, one group per country and one bar per year, with a subtitle
# and the legend of the years
year_bars <- function(m, title, subtitle, filename) {
  open_png(filename)
  barplot(m, beside = TRUE, col = YEAR_COLOURS, border = "grey", main = title, ylim = nice_ylim(m))
  mtext(subtitle, side = 3, line = 0.4, cex = 0.8)
  legend("topright", legend = rownames(m), cex = 0.65, fill = YEAR_COLOURS, border = "white",
         bty = "n")
  dev.off()
}

# Total loans (pink) with performing loans (teal) drawn on top:
# the pink part at the top of each bar is the NPL volume
loans_and_npl_chart <- function(countries, filename) {
  total <- year_matrix(countries, "net_loans_bn", scale = 1, include_ea = FALSE)
  npl   <- year_matrix(countries, "npl_bn", scale = 1, include_ea = FALSE)
  open_png(filename)
  barplot(total, beside = TRUE, col = palette.colors(n = 1, "Pastel1"), border = "grey",
          main = "Volumes of loans and NPL", ylim = nice_ylim(total))
  barplot(total - npl, beside = TRUE, col = palette.colors(n = 1, "Set3"), add = TRUE,
          border = "grey", ylim = nice_ylim(total))
  mtext("2019-2023, by year volumes in billion of Euros", side = 3, line = 0.4, cex = 0.8)
  legend("topright", legend = "NPL Loans", cex = 0.65,
         fill = palette.colors(1, palette = "Pastel1"), border = "white")
  dev.off()
}

# capital_composition_chart(countries, filename)
# Total capital, Tier 1, CET1 and Tier 2 as % of RWAs, drawn on top of each other
# (add = TRUE): total capital is the tallest bar, then Tier 1, CET1 and Tier 2. All four
# layers share the same y axis, computed on the highest value.
capital_composition_chart <- function(countries, filename) {
  layers <- c(total_capital_ratio = "Total Capital", tier1_ratio = "Tier 1",
              cet1_ratio = "CET1", tier2_ratio = "Tier 2")
  colours <- c(palette.colors(n = 1, "Set3"), "yellow", palette.colors(1, palette = "Paired"),
               palette.colors(1, palette = "Pastel1"))
  ylim <- nice_ylim(map(names(layers), ~ year_matrix(countries, .x)))
  open_png(filename)
  for (i in seq_along(layers)) {
    barplot(year_matrix(countries, names(layers)[i]), beside = TRUE, col = colours[i],
            border = "grey", add = i > 1, ylim = ylim,
            main = if (i == 1) "Capital Composition" else NULL)
  }
  mtext("2019-2023, by year % of Total Risk Weighted Assets", side = 3, line = 0.4, cex = 0.8)
  legend("topright", legend = layers, cex = 0.65, fill = colours, border = "white", bty = "n")
  dev.off()
}

# region_roe_chart(...): median bank ROE of a region by year (point) with the interquartile
# range (bar from the 25th to the 75th percentile)
region_roe_chart <- function(regions, region, filename) {
  d <- filter(regions, region == !!region)
  p <- ggplot(d, aes(x = year, y = roe_median)) +
    geom_errorbar(aes(ymin = roe_p25, ymax = roe_p75), linewidth = 3, width = 0.2) +
    geom_point(colour = "#800080", size = 5) +
    xlab("Year") + ylab("ROE") +
    ggtitle(paste0("Distribution of Return on Equity in the ", REGION_NAMES[[region]],
                   " Euro Area \nInterquantile Range of ROE by year")) +
    theme_bw()
  ggsave(file.path(OUT_DIR, filename), p, width = 9.5, height = 5.9, dpi = 300)
}

# region_npl_capital_chart(...): NPL ratio and total capital ratio of a region by year, one
# chart above the other (par(mfrow = c(2, 1)))
region_npl_capital_chart <- function(regions, region, filename) {
  d <- filter(regions, region == !!region)
  name <- REGION_NAMES[[region]]
  open_png(filename, height = 1780)
  par(mfrow = c(2, 1))
  barplot(setNames(d$npl_ratio, d$year), col = "#000080", xlab = "Year",
          main = paste("NPL Ratio", name, "Euro Area"), ylim = nice_ylim(d$npl_ratio))
  barplot(setNames(d$total_capital_ratio, d$year), col = "#5F0000", xlab = "Year",
          main = paste("Total Capital Ratio", name, "Euro Area"),
          ylim = nice_ylim(d$total_capital_ratio))
  dev.off()
}

# make_charts(countries, regions): draws and saves all 14 charts in output/
make_charts <- function(countries, regions) {
  loans_and_npl_chart(countries, "cs1_loans_and_npl.png")
  year_bars(year_matrix(countries, "npl_ratio"), "Non Performing Loans ratio",
            "2019-2023, by year % of total loans", "cs1_npl_ratio.png")
  capital_composition_chart(countries, "cs1_capital_composition.png")
  year_bars(year_matrix(countries, "roe"), "Return on Equity",
            "2019-2023, by year % of Return on Equity", "cs1_roe.png")
  year_bars(year_matrix(countries, "roa"), "Return on Assets",
            "2019-2023, by year % of Return on Assets", "cs1_roa.png")
  year_bars(year_matrix(countries, "nim_median", scale = 1), "Net Interest Margin",
            "2019-2023, by year % of Net Interest Margin", "cs1_nim.png")
  for (region in names(REGIONS)) {
    key <- tolower(region)
    region_roe_chart(regions, region, paste0("cs1_roe_distribution_", key, ".png"))
    region_npl_capital_chart(regions, region, paste0("cs1_npl_capital_", key, ".png"))
  }
}


# ------------------------------------------------------------------------------
# main(): load -> clean -> aggregate -> save tables and charts
main <- function() {
  dir.create(OUT_DIR, showWarnings = FALSE)
  bs   <- apply_sample_filters(load_balance_sheet())
  prof <- apply_sample_filters(load_profitability())
  nim  <- apply_sample_filters(load_nim())

  countries <- country_metrics(bs, prof, nim)
  regions   <- region_metrics(bs, prof)
  write.csv(countries, file.path(OUT_DIR, "cs1_country_metrics.csv"), row.names = FALSE)
  write.csv(regions,   file.path(OUT_DIR, "cs1_region_metrics.csv"),  row.names = FALSE)
  make_charts(countries, regions)

  # Euro area values and macro-regions, printed in the console
  print(filter(countries, country == "EA"), width = Inf)
  print(regions, n = Inf, width = Inf)
}

main()
