# Load libraries
library(sf)          # For geospatial data
library(ineq)        # For Gini Index
library(vegan)       # For biodiversity indices
library(dplyr)       # For data manipulation
library(tidyr)       # For data manipulation
library(tibble)      # For data manipulation
library(spatialreg)  # For Spatial regression
library(spdep)       # For spatial dependence
library(tictoc)
library(naniar)
library(tidyverse)

# parameters per city:
# bogota
birds_fls <- "data/Bogota/Birds/Bogotabirddata.txt"
shp_fls <- "data/Bogota/Valor_ref_2023/Valor_ref_2023.shp"
local_utm <- 32618

# mexico
birds_fls <- "data/Mexico City/Birds/Mexicobirds.txt"
shp_fls <- "data/Mexico City/09_Manzanas_INV2020_shp/INV2020_IND_PVEU_MZA_09.shp"
local_utm <- 32618


#### Clean data ####
# Load bird data
tic()
birds <- read.delim(birds_fls) |> 
    janitor::clean_names() |> 
    as_tibble()
toc()

birds <- birds |> 
    filter(category %in% c("species", "issf")) |> 
    select(scientific_name, obs = observation_count, longitude,latitude) |>
    mutate(obs = case_when(obs == "x" ~ "1", .default = obs),
           obs = as.numeric(obs),
           obs = case_when(is.na(obs) ~ 1, .default = obs)) |> 
    st_as_sf(coords = c("longitude", "latitude"), crs = 4326)

birds

## Load value city data
city <- st_read(shp_fls) |>  # Polygons
    select(value = V_REF)
city |> plot()
# Check CRS of both shapefiles
st_crs(city)
st_crs(birds)

### Both are the same: why is this important? Because 4326 is spherical projection and 32618 is planar. We need a planar projection per city to make comparable hexagones
# If CRS is different, reproject one of them
#birddata <- st_transform(birddata, st_crs(citydata))

# Reproject citydata to UTM (change the EPSG code according to city zone)
city <- st_transform(city, crs = local_utm)

# Reproject birddata to UTM (change the EPSG code according to city zone)
birds <- st_transform(birds, crs = local_utm)

# Generates a hexagonal grid
hex_grid <- st_make_grid(city, cellsize = 500, square = FALSE) %>% 
    st_as_sf() %>% 
    mutate(ID = row_number())

# Calculate centroids: JR: why is this important?
centroids <- st_centroid(hex_grid)

city_centroids <- st_centroid(city)

# centroid_coords <- st_coordinates(centroids) %>%
#     as.data.frame() %>%
#     rename(Longitude = X, Latitude = Y)
# 
# centroid_data <- hex_grid %>%
#     st_drop_geometry() %>%  
#     bind_cols(centroid_coords)  

## Intersect data: everything needs to be at the hexagon level of analysis
# both works as point or polygon for cities.
# tic()
# city_hex<- aggregate(
#     city, 
#     by = hex_grid, FUN = mean, na.rm = TRUE) |> 
#     rename(mean = value)
# toc() #1.8s
tic()
city_hex <- st_intersection(city_centroids, hex_grid)
toc()


city_hex <- city_hex |> 
    st_drop_geometry() |> 
    group_by(ID) |> 
    summarize(
        mean_value = mean(value),
        gini = Gini(value),
        sd_value = sd(value, na.rm = TRUE),
        n_houses = n()
    ) 

hex_grid <- hex_grid |> 
    left_join(city_hex)

# plot(city_hex) # test it works

## For birds is a bit different:
bird_hex <- st_intersection(birds, hex_grid)

bird_hex <- bird_hex |> 
    st_drop_geometry() |> 
    group_by(ID, scientific_name) |> 
    summarize(obs = sum(obs)) |> 
    mutate(
        pct_rank = percent_rank(obs), # not sure this is doing what is supposed to
        grp1 = case_when(
            pct_rank >= 0.90 ~ "common",
            pct_rank <= 0.10 ~ "error",
            TRUE ~ "rare"
        )
    )

bird_hex |> ggplot(aes(obs, pct_rank)) + geom_point(aes(color = grp1))
## ignoring the pct rank for now: it is wrong, he's ignoring the abundant spp

## right join keeps the original number of hex, left join keeps only the ones with spp data
bird_hex <- bird_hex |> 
    group_by(ID) |>
    filter(pct_rank >= 0.5, pct_rank <=0.9) |> 
    summarize(
        richness = specnumber(obs),
        shannon = diversity(obs),
        simpson = diversity(obs, index = "simpson"),
        
    ) 

hex_grid <- hex_grid |> 
    left_join(bird_hex)

## everything is now on hex_grid
rm(bird_hex, briddata, birds, city_hex)

dat <- hex_grid |> 
    mutate(nans = (is.na(mean_value) | is.na(richness))) |> 
    filter(nans == FALSE) #|> 
    #filter(shannon > 0) # remove places where there is only 1 spp


dat |> 
    filter(n_houses > 10) |> 
    ggplot(aes(gini, richness)) +
    geom_point(aes(color = n_houses)) +
    #scale_x_log10() +
    geom_smooth() +
    scale_colour_viridis_c()

dat |> ggplot() + geom_sf(aes(fill = gini)) + lims(y = c(490000, NA))

bogota <- dat


save(bogota, file = "data/bogota.Rda")

#### Regressions ####
coords <- st_centroid(dat) %>% st_coordinates()
nb <- knn2nb(knearneigh(coords, k = 5))
lw <- nb2listw(nb, style = "W")

resp <- names(dat)[5:7]

tic()
fit <- lagsarlm(shannon ~ gini + mean_value + n_houses, dat, lw, method = "eigen")
toc() #3.04 s

tic()
fit2 <- errorsarlm(shannon ~ gini + mean_value, dat, lw, method = "eigen")
toc() #3.3s

tic()
fit3 <- lagsarlm(shannon ~ gini + mean_value, dat, lw, method = "eigen", type = "mixed")
toc() #3s

summary(fit)


plot(dat)


