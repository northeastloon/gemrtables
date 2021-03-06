#if(isTRUE(exists(".gemrtables.pkg.env", mode="environment"))) {
#  .gemrtables.pkg.env.SAVED <- .gemrtables.pkg.env
#  print("Existing environment '.gemrtables.pkg.env' saved as '.gemrtables.pkg.env.SAVED'!")
#}


#' gemrtables
#'
#' \code{gemrtables} is the main function to generate the UNESCO Global
#' Education Monitoring (GEM) Report Statistical tables, returning a dataframe
#' or an xlsx workbook
#'
#' @param region regional grouping on which to compute aggregate values. Options
#'   are `GEMR.region`, `UIS.region` or `SDG.region`. Defaults to `SDG.region`.
#' @param ref_year A four digit numeric of the reference year. Default is two
#'   years prior to the current year.
#' @param export If `TRUE` returns an xlsx workbook in 'wide' format, with
#'   seperate worksheets per table.
#' If `FALSE` (the default) returns a data frame in 'long' format.
#' @param path File path to write xlsx workbook (character). Overwrites existing
#'   file.
#' @param key UIS api subcription key.
#' @param password password to cedar database.
#' @param removeCache Character vector of unprocessed dataframes. Options are c("uis_up", "cedar_up", "wb_up", "eurostat_up", "oecd_up")
#' @return A data frame or an xlsx workbook.
#' @export
#' @examples
#' gemrtables(ref_year = 2016, export = TRUE, path = x, key = y, password = z)
#'
#' df <- gemrtables(region = "UIS.region", ref_year = 2016, export = FALSE, key = y, password = z)

gemrtables <- function(
  region = "SDG.region",
  ref_year,
  export = TRUE,
  path,
  key,
  password,
  pc_flag_cut = 66,
  pc_comp_cut2 = 33,
  removeCache
  ) {

  #define package environment and package wide parameters

  .gemrtables.pkg.env <<- new.env(parent = emptyenv())
  # rm(list = ls(envir = .gemrtables.pkg.env), envir = .gemrtables.pkg.env)

  .gemrtables.pkg.env$ref_year <- ifelse(missing(ref_year), lubridate::year(Sys.Date())-2, as.numeric(ref_year))

  .gemrtables.pkg.env$region = as.name(region)

  .gemrtables.pkg.env$pc_flag_cut <- pc_flag_cut

  .gemrtables.pkg.env$pc_comp_cut2 <- pc_comp_cut2



  if(region == "SDG.region") {
    .gemrtables.pkg.env$subregion <- as.name("SDG.subregion")
  }else if(region == "UIS.region") {
    .gemrtables.pkg.env$subregion <- as.name("UIS.subregion")
  }else if(region == "GEMR.region") {
    .gemrtables.pkg.env$subregion <- as.name("GEMR.subregion")
  }

  #Set directory for cache (users current working directory)

  dir.create(path="./.Rcache", showWarnings=FALSE)
  R.cache::setCacheRootPath(path="./.Rcache")

  if(!missing(removeCache)) {
    for(i in 1:length(removeCache)) {
      file.remove(R.cache::findCache(key=list(removeCache[i])))
    }
  }

  #define api and db keys.

  if (missing(key)) {
    stop("Key for UIS API is missing")
  } else {
    .gemrtables.pkg.env$key <- as.character(key)
  }

  if (missing(password)) {
    stop("Password for cedar sql database is missing")
  } else {
    .gemrtables.pkg.env$password <- as.character(password)
  }

  if (missing(path) & isTRUE(export)) {
    stop("file path not specified")
  } else {
    path <- as.character(path)
  }

  #import / generate other merge files
  .gemrtables.pkg.env$indicators <- inds()
  .gemrtables.pkg.env$regions <- region_groups()
  indicators_unique <- .gemrtables.pkg.env$indicators %>%
    dplyr::select(-source, -var_concat, -priority, -ind_lab) %>%
    unique()
  .gemrtables.pkg.env$regions2 <- region_groups2() %>%
    dplyr::filter(grouping == as.character(.gemrtables.pkg.env$region))

  #load/ cache for imported/cleaned country data and weights

  # function to generate country_data
  c_data <- function() {

    uis_data <- uis()
    cedar_data <- cedar()
    other_data <- other()
    dplyr::bind_rows(uis_data, cedar_data, other_data)
  }

  load_cache_data <- function(df, ref_year = .gemrtables.pkg.env$ref_year) {

    #convert file_paths into of unprocessed datasets into character vector

    source_keys = c("uis_up", "cedar_up", "wb_up", "eurostat_up", "oecd_up")
    sources <- list()
    for(i in seq_along(source_keys)) {
       sources[[i]] <- R.cache::findCache(list(source_keys[i]))
    }
    sources <- unlist(sources, use.names = FALSE)

    # 1. Try to load cached data, if already generated
    key_country <- list(df)
    key_weights <- list(df, ref_year)

    if(df == "country_data") {
      data <- R.cache::loadCache(key_country, sources = sources, removeOldCache=TRUE)
      if(length(sources) !=5) {
        data <- NULL
        }
      }else if (df == "weights_data"){
        data <- R.cache::loadCache(key_weights)
    }

    if (!is.null(data)) {
      cat(paste("Loaded cached", df, "\n", sep = " " ))
      return(data);
    }

    # 2. If not available, generate it.
    cat(paste("Building", df, "...\n", sep = " "))
    if(df == "country_data") {
      data <- c_data()
      R.cache::saveCache(data, key=key_country, comment=df)
      R.cache::loadCache(key_country)
    }else if (df == "weights_data") {
      data <- weights()
      R.cache::saveCache(data, key=key_weights, comment=df)
      R.cache::loadCache(key_weights)
    }
  }

  country_data <- load_cache_data("country_data")
  # if (any(
  #   # is.null(.gemrtables.pkg.env$schol_unspec),
  #   is.null(.gemrtables.pkg.env$uis_comp),
  #   FALSE)) {clearCache(prompt = FALSE)}

  dac_recipients <- read.csv(system.file("config", "DAC_recipients.csv", package = "gemrtables"),
                             stringsAsFactors = FALSE) %>% na.omit

  weights_data <-
    load_cache_data("weights_data") %>%
    dplyr::left_join(select(.gemrtables.pkg.env$regions, iso3c, iso2c, World, SDG.region, SDG.subregion, income_group, income_subgroup), by = 'iso2c') %>%
    tidyr::gather(wt_region, group, World:income_subgroup) %>%
   #dplyr::filter(!stringr::str_detect(ind, 'odaflow') | iso3c %in% dac_recipients$iso3c) %>%
    dplyr::select(-iso3c) %>%
    dplyr::group_by(wt_var, wt_region, group) %>%
    dplyr::mutate(wt_total = sum(wt_value, na.rm = TRUE)) %>%
    dplyr::ungroup()
  pop_data <-
    weights_data %>%
    filter(wt_var == '_T') %>%
    select(iso2c, year, wt_region, group, pop = wt_value, pop_total = wt_total)
  .gemrtables.pkg.env$weights_data <-
    weights_data %>%
    dplyr::left_join(select(pop_data, -year), by = c('iso2c', 'wt_region', 'group')) %>%
    dplyr::select(-year)

  #clean country data and export statistical tables

  country_data1 <- country_data %>%
    dplyr::right_join(.gemrtables.pkg.env$regions, by = "iso2c") %>%
    dplyr::left_join(.gemrtables.pkg.env$indicators, by = c("ind", "source")) %>%
    dplyr::filter(year >= .gemrtables.pkg.env$ref_year - year_cut)

  unmatched <- dplyr::anti_join(.gemrtables.pkg.env$indicators, country_data1, by = c("ind", "source")) %>%
    dplyr::select(ind, source, sheet, position)

  country_data2 <- country_data1 %>%
    dplyr::select(iso2c, annex_name, World, !!.gemrtables.pkg.env$region, !!.gemrtables.pkg.env$subregion, income_group, income_subgroup, year, ind, value, val_status, source) %>%
    dplyr::right_join(.gemrtables.pkg.env$indicators, by = c("ind", "source")) %>%
    dplyr::group_by(iso2c, ind, source) %>%
    dplyr::filter(year == max(year)) %>%
    dplyr::ungroup() %>%
    dplyr::group_by(iso2c, ind) %>%
    dplyr::filter(priority == min(priority)) %>%
    # dplyr::left_join(weights_data[, -3], by = c("iso2c", "wt_var")) %>%
    dplyr::mutate(entity = "country") %>%
    # dplyr::left_join(select(pop_data, -year), by = c('iso2c')) %>%
    ungroup() %>%
    dplyr::mutate(year = ifelse(stringr::str_detect(ind, stringr::regex("XGDP|XGovExp", ignore_case = TRUE)) & iso2c == "ST", 2016, year),
                  value = case_when(stringr::str_detect(ind, stringr::regex("XGDP", ignore_case = TRUE)) & iso2c == "ST" ~ 5.07533,
                                    stringr::str_detect(ind, stringr::regex("XGovExp", ignore_case = TRUE)) & iso2c == "ST" ~ 15.96804,
                                    TRUE ~ value))

  uis_aggregates_extra <- R.cache::evalWithMemoization(uis_extra_aggs())

  uis_aggregates <- R.cache::loadCache(list("uis_comp")) %>%
    dplyr::anti_join(uis_aggregates_extra, by = c('iso2c', 'var_concat', 'year')) %>%
    dplyr::bind_rows(uis_aggregates_extra) %>%
    dplyr::inner_join(.gemrtables.pkg.env$indicators, by = "var_concat") %>%
    dplyr::filter(aggregation %in% c("w_mean", "sum") & year >= (.gemrtables.pkg.env$ref_year - 4)) %>%
    dplyr::inner_join(.gemrtables.pkg.env$regions2[, 1:3], by = c("iso2c" = "code")) %>%
    dplyr::select(-iso2c)

  schol_unspec <- R.cache::loadCache(list("schol_unspec"))

    computed_aggregates <- country_data2 %>%
    aggregates() %>%
    dplyr::filter(!is.na(annex_name)) %>%
    dplyr::inner_join(indicators_unique, by = c("ind", "aggregation", "pc_comp_cut")) %>%
    dplyr::anti_join(uis_aggregates, by = c("annex_name", "ind")) %>%
    dplyr::mutate(value = dplyr::case_when(annex_name == "World" & ind == "odaflow.volumescholarship" ~ value + schol_unspec[[2,2]],
                                           annex_name == "World" & ind == "odaflow.imputecost" ~ value + schol_unspec[[1,2]],
                                           TRUE ~ value))

  long_data <- dplyr::bind_rows(country_data2, computed_aggregates, uis_aggregates)  %>%
    tidyr:: complete(tidyr::nesting(ind, sheet, position), tidyr::nesting(annex_name, !!.gemrtables.pkg.env$region, !!.gemrtables.pkg.env$subregion, entity),
    fill = list(value = NA, val_status = "", year_diff = 0)) %>%
    dplyr::arrange(sheet, position, !!.gemrtables.pkg.env$region, entity, annex_name)

  wide_data <- long_data %>%
    format_wide()

  if(nrow(unmatched > 0)) {
    cat(paste("The following variables are missing:\n"))
    cat(paste(capture.output(print(unmatched)), collapse = "\n"))
  }

  if(isTRUE(export)) {
    writexl::write_xlsx(wide_data, path = path)
  }else {
    return(long_data)
  }
}
