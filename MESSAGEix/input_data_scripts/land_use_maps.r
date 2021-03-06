# land use maps

require(rgeos)
require(rgdal)
require(raster)
require(dplyr)
require(tidyr)
library(ggplot2)

# Location of input data
setwd( 'P:/is-wel/indus/message_indus' )

# Local location of indus ix model - MAKE SURE TO ADD TO SYSTEM ENVIRONMENT VARIABLES
indus_ix_path = Sys.getenv("INDUS_IX_PATH")

# Basin analyzed
basin = 'Indus'

#path with yield data, from GAEZ
maps_path = paste0(getwd(),'/input/land_maps_crop_yields')

#basin shape file
basin.spdf = readOGR( paste( getwd(), 'input', sep = '/' ), paste( basin, 'bcu', sep = '_' ), verbose = FALSE )

#little function to crop raster with basin extent, and assign pids
assign_pid_to_raster = function(input.rs){
  input_cropped.rs = crop( input.rs, basin.spdf )
  input_cropped.sp = rasterToPoints(input_cropped.rs, spatial = T)
  
  input_cropped.sp = spTransform(input_cropped.sp, crs(  basin.spdf ) )
  names(input_cropped.sp) = 'value'
  input_cropped.sp$node = as.character(over(input_cropped.sp , basin.spdf)[,'PID'] )
  input_cropped.sp = input_cropped.sp[!is.na(input_cropped.sp$node),]
  return(input_cropped.sp)
}

# some data should be raster and go to CWaTM
# for MESSAGE model we need to aggregate into catchments:
# - historical harvested area of crops >> becomes installed capacity
# - land availability for rain-fed and irrigated crops
map_cwatm_msg <- data.frame(cwatm = c('forest','grassland', 'irr_rice','non_irr_rice',
                                      'non_irr_rice', 'non_irr_rice', 'non_irr_rice', 
                                      'non_irr_rice', 'built_up_land', 'water_bodies'),
                            msg = c('non_crop', 'non_crop', 'rice', 'wheat', 'cotton',
                                    'fodder', 'sugarcane', 'pulses', 'non_crop', 'non_crop') )

# land use maps as % of used land for different purposes
land_maps_names = c('forest','grassland','built_up_land', 'water_bodies', 'all_cultivated')

for (ii in seq_along(land_maps_names)){
  print(paste0(land_maps_names[ii ] ))
  land_folder = list.dirs(path = maps_path)
  land_folder = land_folder[ grep( paste0( land_maps_names[ii]), land_folder)]
  land_file = list.files(path = land_folder,pattern = '.tif')
  
  tmp_land.rs = raster(paste0(land_folder,'/', land_file) )/100
  
  assign(paste0('land_use_',land_maps_names[ii],'.rs'),tmp_land.rs)
}
# for MESSAGE # land availability = land_use_all_cultivated * area [km2]
area_cultivated.rs = area(land_use_all_cultivated.rs) # km2
land_av_agriculture.rs = area_cultivated.rs * land_use_all_cultivated.rs
land_av_agriculture.sp = assign_pid_to_raster(land_av_agriculture.rs)
land_av_agriculture.df = land_av_agriculture.sp@data %>% 
  group_by(node) %>% 
  summarise(value = sum(value)/10^4) %>%  #from km2 to Mha
  mutate(units = 'Mha')

# crop use maps in terms of 1000 ha per pixel (in year 2000)
crop_names = c('wheat','rice','cotton','fodder','sugarcane','pulses','maize','fruit','vegetables')
irr_land.df = NULL
for (ii in seq_along(crop_names)){
  print(paste0(crop_names[ii ] ))
  crop_land_folder = list.dirs(path = maps_path)
  crop_land_folder = (crop_land_folder[ grep( paste0( crop_names[ii]), crop_land_folder)])[1]
  crop_land_file = list.files(path = crop_land_folder,pattern = '.tif')
  
  # 1000 ha
  tmp_land.rs = raster(paste0(crop_land_folder,'/',crop_land_file) ) * 1000 #makes it in ha
  
  # for CWaTM
  assign(paste0('land_ha_',crop_names[ii],'.rs'),tmp_land.rs)
  
  #process for MESSAGE, 
  # historical capacity: crop to basin catchments and aggregate potential in Mha
  tmp_land.sp = assign_pid_to_raster(tmp_land.rs)
  tmp_land.df = tmp_land.sp@data %>% 
    group_by(node) %>% 
    summarise(value = sum(value )/10^6) %>% 
    mutate(crop = crop_names[ii]) %>% 
    mutate(par = 'crop_irr_land_2000') %>% 
    mutate(unit = 'Mha') %>% 
    mutate(time = 'year') %>% 
    select(crop,par,node,time,unit,value)
  
  irr_land.df = bind_rows(irr_land.df,tmp_land.df)
}
#rainfed land
rainfed_land.df = NULL
for (ii in seq_along(crop_names)){
  print(paste0(crop_names[ii ] ))
  crop_land_folder = list.dirs(path = maps_path)
  crop_land_folder = (crop_land_folder[ grepl( paste0( '_r_', crop_names[ii]), crop_land_folder)])[1]
  crop_land_file = list.files(path = crop_land_folder,pattern = '.tif')
  
  # 1000 ha
  tmp_land.rs = raster(paste0(crop_land_folder,'/',crop_land_file) ) * 1000 #makes it in ha
  
  # for CWaTM
  assign(paste0('land_ha_',crop_names[ii],'.rs'),tmp_land.rs)
  
  #process for MESSAGE, 
  # historical capacity: crop to basin catchments and aggregate potential in Mha
  tmp_land.sp = assign_pid_to_raster(tmp_land.rs)
  tmp_land.df = tmp_land.sp@data %>% 
    group_by(node) %>% 
    summarise(value = sum(value )/10^6) %>% 
    mutate(crop = crop_names[ii]) %>% 
    mutate(par = 'crop_rainfed_land_2000') %>% 
    mutate(unit = 'Mha') %>% 
    mutate(time = 'year') %>% 
    select(crop,par,node,time,unit,value)
  
  rainfed_land.df = bind_rows(rainfed_land.df,tmp_land.df)
}

# check sum or irr area for different crops vs total area for agriculture
check_area = bind_rows(irr_land.df,rainfed_land.df) %>%  
  group_by(node,par) %>% summarise(value = sum(value)) %>% ungroup() %>% 
  tidyr::spread(par,value) %>% 
  left_join(land_av_agriculture.df %>% select(-units) %>% 
              rename( tot_land_av = value)) %>% 
  mutate(diff = (tot_land_av - (crop_rainfed_land_2000 + crop_irr_land_2000)  )/tot_land_av *100 ) %>% 
  mutate(tot_crop_area = crop_rainfed_land_2000 + crop_irr_land_2000) %>% 
  select(node,diff,everything()) 
# for four nodes the sum of irrigated land is higher than total land available 
# the max difference is 16% in PAK_5
ggplot(check_area %>% 
         tidyr::gather('type','value',3:6))+
  geom_point(aes(x = node, y = value, color = type))+
  theme_bw()
  
check_rain_irr_ratio = check_area %>% select(node,crop_irr_land_2000,crop_rainfed_land_2000) %>% 
  mutate(ratio = crop_irr_land_2000/crop_rainfed_land_2000,
         perc_on_tot = crop_rainfed_land_2000/(crop_irr_land_2000 + crop_rainfed_land_2000)*100)

national_trend.path = path.expand(paste0(maps_path,'/FAO_hist_national_prod'))
nat_trend.files = list.files(path = national_trend.path,pattern = '.csv')

#calculate the multiplication factor for 2015, China data just remain unchanged as in 2000
# from FAO national harvested area 1990-2015 trends, used as multiplication factors for the spatial harvested area in 2000
# this gives the historical capacity of crop technologies in 2015
perc_inc2015 = NULL
for (jj in seq_along(nat_trend.files)){
  
  tmp_national = read.csv(paste0(national_trend.path,'/',nat_trend.files[jj])) %>% 
    filter(Unit == 'ha', Year %in% c(2000,2015) ) %>% 
#    mutate(Value = Value * 1E-6, Unit = 'Mha') %>% # Mha
    group_by(Area,Item) %>% 
#    mutate(mult = (lm(Value ~ Year)$coefficients[[2]]) ) %>%
    mutate(Year = paste0('v',Year)) %>% 
    select(Area,Item,Year,Unit,Value) %>% 
    spread(Year,Value) %>% 
    mutate(perc_inc = (v2015-v2000)/v2000) %>% 
    select(Area,Item,Unit,perc_inc)
  # we want only mult at the end
  perc_inc2015 = bind_rows(perc_inc2015,tmp_national)
}

perc_inc2015[ perc_inc2015$Area == 'Pakistan' & perc_inc2015$Item == 'Oranges',]$Item = 'Fruit, citrus nes'
veg_to_aggregate = perc_inc2015 %>% 
  filter(Item %in% c('Onions, dry', 'Potatoes')) %>% 
  group_by(Area,Unit) %>% summarise(perc_inc = mean(perc_inc)) %>% ungroup() %>% 
  mutate(Item = 'vegetables') %>% select(Area,Item,Unit,perc_inc)

perc_inc2015 = perc_inc2015 %>% 
  filter(!Item %in% c('Onions, dry', 'Potatoes')) %>% 
  bind_rows(veg_to_aggregate)

crop_item_map = data.frame(Item = unique(perc_inc2015$Item),
                           crop = c('cotton', 'pulses', 'rice','sugarcane','wheat','fodder','maize','fruit','vegetables' ) )
country_map = data.frame(Area = unique(perc_inc2015$Area),
                         node2 = c('AFG', 'IND', 'PAK') )

perc_inc2015 = perc_inc2015 %>% left_join(crop_item_map) %>% 
  left_join(country_map) %>% ungroup() %>% 
  select(node2,crop,perc_inc) %>% unique() %>% 
  bind_rows(expand.grid(node2 = 'CHN',crop = crop_names, perc_inc = 0) )

out_df = bind_rows(irr_land.df,rainfed_land.df) %>% 
  mutate(node2 = gsub('_.*','',node) ) %>% 
  left_join(perc_inc2015) %>% 
  mutate(value = if_else(value == 0,0 ,value + (value* perc_inc)) ) %>% 
  mutate(par = if_else(grepl('2000',par), gsub('2000','2015',par), par)) %>% 
  select(crop,par,node,time,unit,value)

# check after 2015 upscaling
check_area2 = out_df %>%  
  group_by(node,par) %>% summarise(value = sum(value)) %>% ungroup() %>% 
  tidyr::spread(par,value) %>% 
  left_join(land_av_agriculture.df %>% select(-units) %>% 
              rename( tot_land_av = value)) %>% 
  mutate(diff = (tot_land_av - (crop_rainfed_land_2015 + crop_irr_land_2015)  )/tot_land_av *100 ) %>% 
  mutate(tot_crop_area = crop_rainfed_land_2015 + crop_irr_land_2015) %>% 
  select(node,diff,everything())

#write available land for agriculture, use tot available land 2000 when it is greater than the sum of rainfed+irr land in 2015
# otherwise use rainfed + irr land 2015
land_av_agriculture.df = check_area2 %>% 
  group_by(node) %>% 
  mutate(value = max(tot_land_av,tot_crop_area),
         units = 'Mha') %>% ungroup() %>% 
  select(node,value,units)

write.csv(land_av_agriculture.df, paste0(getwd(),'/input/land_availability_map.csv'), row.names = F  )

existing_csv = read.csv(paste0(getwd(), '/input/crop_input_data.csv')) %>% 
  filter(unit != 'Mha')
to_csv = bind_rows(existing_csv, out_df)
write.csv(to_csv, paste0(getwd(), '/input/crop_input_data.csv'), row.names = F )

## FOR CWATM
# km2 = 100 ha
area_rice.rs = area(land_ha_rice.rs) * 100
b = values(area_rice.rs)
hist(b)

# for CWaTM we need % of land with paddy and non paddy
# percentage of land avalable for rice in each pixel
# where land_rice is not define, we get Na, should reconvested to 0
perc_rice.rs = land_ha_rice.rs / (area_rice.rs) 
perc_rice.rs[is.na(perc_rice.rs)] = 0
c = values(perc_rice.rs)
c = c[c != 0]
hist(c)
max(c) # should be lower than 1, when cropping to basin is <1 but if we want to use global maps is not good
plot(perc_rice.rs)

#chekc sumof other crops for CWatm, it should not exceed 1 
sum_other_crops.rs = land_ha_cotton.rs + land_ha_fodder.rs + land_ha_pulses.rs + land_ha_sugarcane.rs + land_ha_wheat.rs
perc_other.rs = sum_other_crops.rs / (area_rice.rs)
perc_other.rs[is.na(perc_other.rs)] = 0
d = values(perc_other.rs)
d = d[d != 0]
hist(d)
max(d)

# perc_rice.rs = crop( perc_rice.rs, basin.spdf )
# 
# perc_other.rs = crop( perc_other.rs, basin.spdf )




perc_rice.rs = crop( perc_rice.rs, basin.spdf )

