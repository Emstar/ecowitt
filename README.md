# ecowitt
This project uses a bash script and web server to let you to see the status of all of your Ecowitt soil moisture sensors in one concise web page.

<img width="1000" alt="image" src="https://github.com/user-attachments/assets/539045df-09fc-4f1b-a251-a7f94247232a" />

## Requirements
This project was designed to work with the Ecowitt GW1100 hub updated to software version `GW1100B_V2.4.3` (mid-August 2025). It relies on the availability of a JSON data file that can be fetched with an URL in this format:

`http://hub_ip_address/get_livedata_info`

Other Ecowitt hubs will probably work. This release may work with Ecowitt clones such as Ambient Weather, I don't know.

This monitor code is intended to run on some machine on your LAN which has a web server and the ability to run `bash` scripts. You will also need to install these packages if you don't already have them:

* `jq`
* `curl`
* `awk`

The monitor web page uses a lot of JavaScript and so requires a semi-modern browser. 

## Why does this exist?
This display has two main enhancements over the official Ecowitt web app. 

1. It provides a very compact view including a 24 hour strip chart for each sensor, so you can fit more information onto a small display like an old tablet. 
2. It allows you to customize the moisture value to color mapping for each sensor. **The entire point of this tool is to be able to glance at a page and see what's good (green) and what needs attention (any other color).** 

### Other features

* Up to 4 Ecowitt hubs are supported, and the system should automagically pick up new sensors when they come online.
* The system will log the details of the last data fetch, and any errors it encountered -- look at the footer.
* User-customized values for color mapping are broken out into a separate HTML file, separating code and content for the most part

Clicking or tapping on a mini chart will open a zoomed in 24 hour view, and you can touch or mouse over the chart to see the moisture value at that time. This is easier and faster than digging around in the official Ecowitt charts, but you'll still need to use their app if you want to see more than 24 hours of history. 

<img width="600" alt="image" src="https://github.com/user-attachments/assets/e4b9d7ad-4213-4d03-8f12-3018bf6557e5" />

Note that the zoomed view also prints the color mapping details in use for that sensor. 

## Method of operation
Via `cron`, the bash script `getdata.sh` grabs the current sensor data JSON file from the GW1100 hub once per minute. `getdata.sh` will create or update several files every time it runs. 

* The current sensor data is written as `data-n.sh` where `n` is the ID of the sensor hub, `1` to `4`. 
* The timestamp of the current data file(s) are written into `timestamp.json`
* The timestamp and nature of the last fetch error, if present, is written as `lasterror.json`
* The last fetched sensor data is written into `chart.csv`; this file is also pruned so that it contains only the last 24 hours of per-minute data.

Your own edits to the moisture value/color maps will be stored in `customization.html`. 

When you view `index.html` in a browser, it looks at all data files, all timestamp files, the customization file, and the chart file to produce the sensor display. 

## Installataion and configuration

**Grab the latest release from this repo and unzip it.** 

**Create a directory for the monitor page in your web server file system.** For example if the root of the server is `/var/www/html` (default for `nginx`) then you may want to create `/var/www/html/ecowitt`. Copy `getdata.sh`, `index.html`, `customization.html` into this directory. Make sure that the file ownership and permissions are correct. You should be able to view the page in your web browser, though it won't work yet. 

**Edit `getdata.sh`, locate the sensor config block and plug in your own sensor hub IP address or addresses.** It should work if at least one of the 4 hubs are configured. It is possible that other Ecowitt hubs provide a valid JSON file at a path other than `/get_livedata_info`, I don't know. 

```
# --- Configuration for Sensor Hubs ---
# Uncomment and configure DATA_URL_2, DATA_URL_3, DATA_URL_4 if you have more sensor hubs.
# The corresponding data-N.json files will be generated in the script's directory.
DATA_URL_1="http://192.168.1.27/get_livedata_info"
DATA_URL_2="" # Example: "http://192.168.1.28/get_livedata_info"
DATA_URL_3="" # Example: "http://192.168.1.29/get_livedata_info"
DATA_URL_4="" # Example: "http://192.168.1.30/get_livedata_info"
```
I have not tested changes to logging frequency or file locations, and recommend leaving all of that untouched. 

**In ``customization.html`` you may edit color mapping per sensor, and decide if you wish to see the hub ID with the sensor name.** 

At first you probably do not have any custom color maps in mind. After you have taken some notes, uncomment a line for that sensor ID and tweak the values. 

* "Good" means "stable" and is green when the sensor value is >= the configured value. 
* "Fair" means "water any time" and is yellow when the sensor value is >= the configured value, but < "good."
* "Warning" means "water ASAP" and is orange when the sensor value is >= the configured value, but < "fair."
* "Critical" means just that, and is red when the sensor value is < the "warning" value

```
const SENSOR_MOISTURE_THRESHOLDS = {
    // Use the sensor's channel ID as the key (e.g., "1", "2", "3")
    // "1": { good: 40, fair: 30, warning: 20, critical: 0 },
    // "2": { good: 40, fair: 38, warning: 36, critical: 0 },
    // "3": { good: 32, fair: 30, warning: 28, critical: 0 },
    // "4": { good: 50, fair: 45, warning: 43, critical: 0 },
    // "5": { good: 35, fair: 33, warning: 31, critical: 0 },
    // "6": { good: 49, fair: 45, warning: 40, critical: 0 },
    // "7": { good: 39, fair: 38, warning: 37, critical: 0 },
    // "8": { good: 31, fair: 29, warning: 28, critical: 0 },
    // "9": { good: 25, fair: 23, warning: 21, critical: 0 }
};
```

**In ``customization.html`` decide if you wish to see the hub ID with the sensor name.**

If you only have sensors on one hub, then the default state of not showing the hub ID is more tidy. 

```
// Set to `false` to hide the hub ID (e.g., "[1]") from the sensor names.
// If you use more than one hub, configure them in getdata.sh 
const showHubId = false;
```

**With the files configured, start the script.** Make sure `getdata.sh` is executable and manually run it with  `./getdata.sh` to make sure it creates the data file, timestamp files, and chart file. 

`getdata.sh` is intended to be run once a minute via `cron`. Once you can run the script manually and see that it works, do `crontab -e` and add a line like this, using the path to `getdata.sh` in the correct web server directory. 

`* * * * * /var/www/html/ecowitt/getdata.sh >> /tmp/script.log /dev/null 2>&1`

## Customizing the color map
Different potting soil mixes have different water retention properties, and plants need different things. It's not possible to generalize the values provided by the sensors. If you take some time to write notes on what moisture number corresponds to what that plant needs, you will soon be able to tweak the color mapping. That means you can glance at the sensor and know that **green is good.** 

Water your plants as usual, and every day or so stick your fingers in the soil and write down your observations with the sensor value. Do not be surprised to find that different soils provide wildly different values. Eventually you will learn something like, _for this plant, anything over 35% is fine, 33-34% means the top 2" is a little dry and watering it is OK, at 32% it needs water urgently, and below that it's critical._ You can then uncomment the line for that sensor ID in `customization.html` and edit the values.

 In some soils you may fine that a 1-2% change in the sensor value makes a dramatic change in how the soil feels, and what the plant needs.

### Sensor calibration?
It's possible to calibrate the AD values in Ecowitt soil sensors, to try and make the displayed moisture percentate more physically meaningful. There's no reason not to do this if you wish to, but I decided not to do that work. Whether you do calibration or not, once you have customized a color map, try not to move the sensor as this may require changes to your color map values.

## Troubleshooting

If `getdata.sh` does not work, make sure you have `bash` installed, and that the script is executable. 

Make sure you can fetch the JSON data file from `http://hub_ip_here/get_livedata_info`. Everything hinges on that. 

Verify ownership and permissions for the web directory and script file are correct. You may have a mismatch between the `cron` user and the owner of the web site files. 

If the battery icons do not work a firmware update is probably needed--as of GW1100 v2.4.3 Ecowitt changed soil sensors to report the number of bars in the battery icon instead of a voltage. I assume other Ecowitt hubs have made the same change.

## Development

**This was a _vibe coding_ experiment. The output is not elegant. If you are a real developer you should run away and make your own.** 

The free Gemini Flash 2.5 did a pretty good job of following my instructions and writing useful code and overall, this was fast and fun. 

I knew generally how I wanted this tool to be structured, so I gave it detailed instructions like. "Create a bash script, intended to run once per minute, that grabs the JSON data at this URL and stores it as data-1.json ... Find the moisture meter information in the JSON... In the fetch script, use the data in the JSON file to create a CSV file chart.csv with the last 24 hours of moisture data... OK now create an HTML page that parses data-1.json and chart.csv, displaying each sensor in a small tile..." 

While Gemini could follow instructions pretty well, it does not know what looks good. Telling it "make the title a little smaller" doesn't work very well. Saying "30% smaller" is better. Better yet is locating the specific value in the CSS, tweaking it yourself, and then telling it to use that specific value (px or rem). In the end, cosmetics took more time than functional code. 

A major hassle was refactoring the code to use sensor ID numbers instead of names. For some reason it decided to structure the code around names at first, but I was the real dummy for letting it do that and postponing the fix. As with an dev project, get your foundation correct, or you will pay it back with interest later. 

The bigger the script and HTML codebase got, the worse Gemini behaved. By the end of the project, I could tell it to make a simple text change, and change _nothing_ else, and it would spit out code that was completely broken. Sometimes it would revert to code from days back in the chat. This would happen even if I gave it a complete recent, good file to use as a starting point. Eventually I restarted a new chat to help it forget useless history, but that did not restore its performance entirely. The last couple of changes on the project had me asking it to create code snippets which I merged manually, as it had lost it's freakin' mind. In my experience this project is right at the limit of what Gemini Flash 2.5 can do. I'll try a different model next time I do anything like this. 

