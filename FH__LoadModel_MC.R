library(kwb.odm)
library(kwb.utils)
library(kwb.ogre)
require(dplyr)

# directories to be adapted by user:

# 1. directory of scripts
# script.dir <- "C:/Users/Fine/Desktop/Diplomarbeit/LoadModel"

# 2. directory of additional data
data.dir <- "C:/Users/Fine/Desktop/Diplomarbeit/LoadModel/data_LoadModel"

# Define unit conversion factors
CONVERSION_FACTORS <- c(
  "mg/L" = 1 / 1000,
  "MPN/100 mL" = 10000,
  "PFU/100 mL" = 10000,
  "PFU/L" = 1000,
  "GC/L" = 1000
)

# Define file types (name without extension and content description)
FILE_TYPES <- c(
  NEU_meanln_sdln = "annual mean concentrations of rainwater",
  BKE_meanln_sdln = paste("annual mean concentrations of rainwater with", 
                          "wrong connections"),
  Vol_rain        = "rain runoff",
  Vol_sewage      = "sewage runoff",
  substance_info  = "removal rates at WWTP/substance information WWTP"
)

# MAIN -------------------------------------------------------------------------
if (FALSE)
{
  # number of Monte Carlo simulations
  runs <- 1000 
  
  # 1. calculate loads of rainwater-based substances (for three pathways) 
  
  # proportion of wrong connections in seperate sewer system
  prop.wrong <- 0
  
  x_annual_loads_rain <- annual_load_rain(data.dir, FILE_TYPES)
  
  # 2. calculate loads of sewage based substances 
  
  x_annual_loads_sew <- annual_load_sewage(data.dir, FILE_TYPES)
}

### FUNCTIONS ###

# annual_load_rain -------------------------------------------------------------
annual_load_rain <- function # calculates the load for each substance
### separates pathways (rain runoff, CSO and WWTP)
(
  data.dir,
  ### path of model data (annual mean concentrations "NEU_meanln_sdln.csv",
  #### mean concentrations with wrong connections "BKE_meanln_sdln.csv"
  ### rain runoff volumes "Vol_rain.csv, 
  ### removal at WWTP "substance_info.csv")
  types
) 
{
  # load data
  name <- "NEU_meanln_sdln"
  x_conc_NEU <- readTableOrStop(data.dir, name, types[name])
  
  name <- "BKE_meanln_sdln"
  x_conc_BKE <- readTableOrStop(data.dir, name, types[name])
  
  name <- "Vol_rain"
  vol_rain <- readTableOrStop(data.dir, name, types[name])
  
  name <- "substance_info"
  removal_rates <- readTableOrStop(data.dir, name, types[name])
  
  ### loads of rainwater based substances via separate sewer system and CSO
  
  # Step 1: Monte Carlo simulations to get concentrations in rainwater with 
  # proportion of wrong connections (prop.wrong)
  
  MC_conc_rain <- initMonteCarlo(x = x_conc_NEU, runs = runs, seed = 0)
  
  MC_conc_rain_wrongcon <- initMonteCarlo(x = x_conc_BKE, runs = runs, seed = 1)
  
  MC_conc_rain_sep <- prop.wrong * MC_conc_rain_wrongcon + 
    (1 - prop.wrong) * MC_conc_rain
  
  #hist(log10(MC_conc_rain_wrongcon$`Escherichia coli`), breaks = 100)
  
  # Step 2: Monte Carlo simulations to get rain volumes
  
  MC_vol_rain <- initMonteCarlo(
    x = vol_rain, runs = runs, log = FALSE, set.names = FALSE, seed = 3
  )
  
  # get SUW-names and paths
  MC_vol_rain_1 <- vol_rain[, 1:2]
  MC_vol_rain <- cbind(MC_vol_rain_1, t(MC_vol_rain))
  
  # Provide units
  units <- selectColumns(x_conc_NEU, "UnitsAbbreviation")
  
  # Step 3: Calculation of loads in rainwater (in list), sep + CSO
  
  load_rain_sep <- getLoads(
    concentration = MC_conc_rain_sep,
    units = units, 
    volume = MC_vol_rain,
    parameter = "ROWvol, Trennsystem [m3/a]"
  )
  
  load_rain_cso <- getLoads(
    concentration = MC_conc_rain,
    units = units,
    volume = MC_vol_rain,
    parameter = "ROWvol, CSO [m3/a]"
  )
  
  ## Calculation of loads in rainwater (in list), WWTP
  
  # Step 1: MC to get concentration in rainwater and rain volume calculation is 
  #   already done (MC_conc_rain, MC_vol_rain)
  
  # Step 2: Monte Carlo simulations to get removal rates
  
  # missing removal rates (mean and sd) are set = 0
  removal_rates$Retention <- defaultIfNA(removal_rates$Retention, 0)
  removal_rates$Retention_sd <- defaultIfNA(removal_rates$Retention_sd, 0)
  
  # get removal rates for substances in x_conc_NEU only (and in same order)
  removal_rates_red <- x_conc_NEU[, 1:2]
  indices <- match(removal_rates_red$VariableName, removal_rates$VariableName)
  removal_rates_red$mean <- removal_rates$Retention[indices]
  removal_rates_red$sd <- removal_rates$Retention_sd[indices]
  
  MC_removal_rates <- initMonteCarlo(
    x = removal_rates_red, runs = runs, log = FALSE, set.names = TRUE, seed = 4
  )
  
  # Step 3: Calculation of loads in list, WWTP
  load_rain_wwtp <- getLoads(
    concentration = MC_conc_rain,
    units = units,
    volume = MC_vol_rain,
    parameter = "ROWvol, WWTP [m3/a]",
    removal = MC_removal_rates
  )
  
  # sum paths (in list)
  load_rain_sum <- sumPaths(
    suwNames = unique(vol_rain$SUW),
    variables = colnames(MC_conc_rain),
    runs = runs,
    inputs = list(load_rain_cso, load_rain_sep, load_rain_wwtp)
  )
  
  # output
  list(
    load_rain_sep = load_rain_sep, 
    load_rain_cso = load_rain_cso, 
    load_rain_wwtp = load_rain_wwtp, 
    load_rain_sum = load_rain_sum,
    MC_vol_rain = MC_vol_rain
  )
}

# readTableOrStop --------------------------------------------------------------
readTableOrStop <- function
(
  data.dir, name, type, 
  ...
  ### additional arguments passed to read.table and eventually overriding our
  ### default settings
)
{
  # Compose the full path to the file
  filename <- paste0(name, ".csv")
  file <- file.path(data.dir, filename)
  
  if (! file.exists(file)) {
    
    stop(sprintf(
      "File with %s (%s) not found in data.dir (%s)", type, filename, data.dir
    ))
  }
  
  # Set default arguments
  args <- list(sep = ";", dec = ".", stringsAsFactors = FALSE, header = TRUE)
  
  # Call read.table with the default arguments but eventually overriden by
  # additional arguments given in "...". callWith() is from "kwb.utils"
  callWith(read.table, args, file = file, ...)
}

# initMonteCarlo ---------------------------------------------------------------
initMonteCarlo <- function
(
  x, runs, log = TRUE, set.names = TRUE, column.mean = "mean", column.sd = "sd", 
  seed = NULL
)
{
  # Set the seed for the random number generator if a seed is given
  if (! is.null(seed)) {
    set.seed(seed)
  }
  
  # Set the normal distribution function to either rlnorm() or rnorm()
  FUN.norm <- ifelse(log, rlnorm, rnorm)
  
  # Create a vector of row indices 1:nrow(x)
  rows <- seq_len(nrow(x))
  
  # For each row index, call a function that looks up the mean and the standard
  # deviation from the appropriate columns and calls the normal distribution
  # function with these values. The result is a list. 
  result <- lapply(rows, FUN = function(row) {
    FUN.norm(n = runs, x[row, column.mean], x[row, column.sd])
  })
  
  # Provide a vector of (column) names
  
  names <- if (set.names) {
    as.character(x$VariableName) 
  } else {
    paste0("X", rows) # Default names: X1, X2, X3, ...
  }
  
  # Convert the list into a data frame and set the column names of that
  # data frame by setting its attribute "name". Use structure() to nicely set
  # attributes "on the fly"
  structure(as.data.frame(result), names = names)
}

# toNumeric --------------------------------------------------------------------
toNumeric <- function(x, columns)
{
  for (column in columns) {
    x[, column] <- as.numeric(x[, column])
  }
  
  x
}

# getLoads ---------------------------------------------------------------------
getLoads <- function
(
  concentration, 
  ### concentration of rain (for CSO) or rain with wrongcons (for sep) or sewage
  ### (CSO)
  units, 
  ### abbreviated unit names
  volume, 
  ### rainwater or sewage volume
  parameter,
  removal = NULL
)
{
  suwNames <- unique(volume$SUW)
  
  # Filter volume data frame for the given parameter
  volume <- volume[volume$Parameter == parameter, ]
  
  # calculate loads in list
  load_x <- lapply(seq_len(ncol(concentration)), function(i) {
    
    # Initialise the output data frame with a unit column
    out <- data.frame(unit = rep(units[i], times = nrow(concentration)))
    
    # Get the loads for each SUW
    for (suwName in suwNames) {
      
      # From the volume data frame, already filtered for the given parameter,
      # select the row representing the current SUW name. 
      volume_suw <- volume[volume$SUW == suwName, ]
      
      # Add an empty column, named according to the current SUW
      out[, suwName] <- NA
      
      # Fill the empty column with the actual loads, calculated for each run
      for (run in seq_len(runs)) {
        
        # Skip the first 2 columns, SUW and Parameter, in volume_suw: 2 + run
        load <- concentration[run, i] * volume_suw[, 2 + run]
        
        # Lookup the removal rate or set it to 0 if no removals are given
        removalRate <- if (is.null(removal)) 0 else 0.01 * removal[run, i]
        
        out[run, suwName] <- load * (1 - removalRate)
      }
    }
    
    changeunit(out)
  })
  
  structure(load_x, names = colnames(concentration))
}

# changeunit--------------------------------------------------------------------
changeunit <- function(x, factors = CONVERSION_FACTORS)
{
  #x <- load_x
  
  unit <- as.character(unique(selectColumns(x, "unit")))
  
  if (is.na(factors[unit])) {
    
    stop("No conversion factor defined for unit: '", unit, "'! Conversion ", 
         "factors are defined for: ", stringList(names(factors)))
  }
  
  # apply conversion of values to all columns except for "unit"
  columns <- setdiff(names(x), "unit")
  
  x[, columns] <- x[, columns] * factors[unit]
  
  x
}

# sumPaths ---------------------------------------------------------------------
sumPaths <- function(suwNames, variables, runs, inputs)
{
  out.init <- data.frame(matrix(ncol = length(suwNames), nrow = runs))
  colnames(out.init) <- suwNames
  
  result <- lapply(seq_along(variables), function(i) {
    
    out <- out.init
    
    for (j in seq_along(suwNames)) {
      
      # Get the appropriate column vectors from the input lists
      vectors <- lapply(inputs, function(input) input[[i]][, 1 + j])
      
      # Calculate the sum vector and assign it to out[, j]
      out[, j] <- Reduce("+", vectors)
    }
    
    out
  })
  
  structure(result, names = variables)
}

# annual_load_sewage ----------------------------------------------------------- 
annual_load_sewage <- function # calculates the load for each substance
### separates pathways (CSO and WWTP)
(
  data.dir,
  ### path of model data("Vol_sewage.csv",
  ### removal at WWTP "substance_info.csv",
  ### just for names "x_conc_NEU")
  types
) 
{
  # load data
  name <- "NEU_meanln_sdln"
  x_conc_NEU <- readTableOrStop(data.dir, name, types[name])
  
  name <- "Vol_sewage"
  vol_sewage <- readTableOrStop(data.dir, name, types[name])
  
  name <- "substance_info"
  sub_sew_info <- readTableOrStop(data.dir, name, types[name])
  
  ### loads of sewage based substances via CSO and WWTP
  
  # Step 1: Monte Carlo Simulations to get sewage volume
  
  MC_vol_sew <- initMonteCarlo(
    x = vol_sewage, runs = runs, log = FALSE, set.names = FALSE, seed = 2
  )
  
  MC_vol_sew_1 <- vol_sewage[, 1:2]
  MC_vol_sewage <- cbind(MC_vol_sew_1, t(MC_vol_sew))
  
  # Step 2: Monte Carlo simulations to get removal rates, concentrations of 
  # influent/effluent WWTP
  
  # read substance information
  # set retention to zero, where information is lacking
  sub_sew_info$Retention[is.na(sub_sew_info$Retention)] <- 0
  sub_sew_info$Retention_sd[is.na(sub_sew_info$Retention_sd)] <- 0
  
  # MC to get retention
  MC_retention <- initMonteCarlo(
    x = sub_sew_info, runs = runs, log = FALSE, set.names = TRUE,
    column.mean = "Retention", column.sd = "Retention_sd", seed = 6
  )
  
  # MC to get concentrations in wastewater
  MC_conc_sew <- initMonteCarlo(
    x = sub_sew_info, runs = runs, log = TRUE, set.names = TRUE, 
    column.mean = "CinWWTP_calculated", column.sd = "CinWWTP_sd", seed = 7
  )
  
  # MC to get effluent concentrations - WWTP
  MC_Cout_WWTP <- initMonteCarlo(
    x = sub_sew_info, runs = runs, log = TRUE, set.names = TRUE, 
    column.mean = "CoutWWTP", column.sd = "CoutWWTP_sd", seed = 8
  )
  
  # Provide units
  units <- selectColumns(x_conc_NEU, "UnitsAbbreviation")
  
  # Step 3: Calculation of loads in list, CSO + WWTP
  
  ## CSO
  load_sew_cso <- getLoads(
    concentration = MC_conc_sew,
    units = units, 
    volume = MC_vol_sewage, 
    parameter = "ROWvol, CSO [m3/a]"
  )
  
  ## WWTP
  load_sew_wwtp <- getLoads(
    concentration = MC_conc_sew, 
    units = units,
    volume = MC_vol_sewage,
    parameter = "ROWvol, WWTP [m3/a]",
    removal = MC_retention
  )
  
  # sum paths (in list)
  load_sew_sum <- sumPaths(
    suwNames = unique(vol_sewage$SUW),
    variables = colnames(MC_conc_sew),
    runs = runs,
    inputs = list(load_sew_cso, load_sew_wwtp)
  )
  
  # output
  list(
    load_sew_cso = load_sew_cso,
    load_sew_wwtp = load_sew_wwtp,
    load_sew_sum = load_sew_sum,
    MC_vol_sewage = MC_vol_sewage
  )
}
