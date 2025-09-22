#!/usr/bin/env python3

# <xbar.title>Weather - OpenWeatherMap</xbar.title>
# <xbar.version>v1.3</xbar.version>
# <xbar.author>Daniel Seripap</xbar.author>
# <xbar.author.github>seripap</xbar.author.github>
# <xbar.desc>Grabs simple weather information from openweathermap. Needs configuration for location and API key.</xbar.desc>
# <xbar.image>https://poolis.github.io/bitbar-plugins/open-weather-preview.png</xbar.image>
# <xbar.dependencies>python,emoji</xbar.dependencies>
# <xbar.var>string(VAR_LOCATION="San Francisco, US"): Your location in the format: city name, country code.</xbar.var>

import emoji
import json
from urllib.request import urlopen
from urllib.error import URLError
from random import randint
import datetime
import os
from config import api_key

location_name = "{0}".format(os.getenv('VAR_LOCATION')).replace(" ", "%20")

units = 'imperial'  # kelvin, metric, imperial
lang = 'en'

def get_wx():
    if api_key == "":
        return False

    try:
        daily_wx = json.load(urlopen(f'http://api.openweathermap.org/data/2.5/forecast/daily?q={location_name}' \
                                     f'&units={units}&lang={lang}&appid={api_key}&v={str(randint(0, 100))}'))
        location = str(daily_wx['city']['id'])
        wx = json.load(
            urlopen(
                'http://api.openweathermap.org/data/2.5/weather?id=' + location + '&units=' + units + '&lang=' + lang + '&appid=' + api_key + "&v=" + str(
                    randint(0, 100))))
    except URLError:
        return False

    if units == 'metric':
        unit = 'C'
    elif units == 'imperial':
        unit = 'F'
    else:
        unit = 'K'  # Default is kelvin

    try:
        daily_forecast = []
        for day in daily_wx['list']:
            daily_forecast.append({'id': day['weather'][0]['id'],
                                   'datetime': datetime.datetime.fromtimestamp(day['dt']),
                                   'max': str(int(round(day['temp']['max']))),
                                   'min': str(int(round(day['temp']['min'])))
                                  })
        weather_data = {
            'temperature': str(int(round(wx['main']['temp']))),
            'condition': str(wx['weather'][0]['description']),
            'id': wx['weather'][0]['id'],
            'city': wx['name'],
            'unit': '°' + unit,
            'daily_forecast': daily_forecast
        }
    except KeyError:
        return False

    return weather_data


def get_gradient_color(temperature):
    temp = int(temperature)
    if temp >= 85:
        return "red"
    elif temp >= 75:
        return "orange"
    elif temp >= 68:
        return "yellow"
    elif temp >= 61:
        return "lime"
    elif temp >= 32:
        return "blue"
    else:
        return "white"

def render_wx():
    weather_data = get_wx()
    emoji_dict = {
        200: ":cloud_with_lightning_and_rain:", 201: ":cloud_with_lightning_and_rain:", 202: ":cloud_with_lightning_and_rain:", 210: ":cloud_with_lightning_and_rain:", 211: ":cloud_with_lightning_and_rain:", 212: ":cloud_with_lightning_and_rain:", 221: ":cloud_with_lightning_and_rain:", 230: ":cloud_with_lightning_and_rain:",
        231: ":cloud_with_lightning_and_rain:", 232: ":cloud_with_lightning_and_rain:",
        300: ":umbrella_with_rain_drops:", 301: ":umbrella_with_rain_drops:", 302: ":umbrella_with_rain_drops:", 310: ":umbrella_with_rain_drops:", 311: ":umbrella_with_rain_drops:",
        312: ":umbrella_with_rain_drops:", 313: ":umbrella_with_rain_drops:", 314: ":umbrella_with_rain_drops:", 321: ":umbrella_with_rain_drops:",
        500: ":umbrella_with_rain_drops:", 501: ":umbrella_with_rain_drops:", 502: ":umbrella_with_rain_drops:", 503: ":umbrella_with_rain_drops:", 504: ":umbrella_with_rain_drops:",
        511: ":umbrella_with_rain_drops:", 520: ":umbrella_with_rain_drops:", 521: ":umbrella_with_rain_drops:", 522: ":umbrella_with_rain_drops:", 531: ":umbrella_with_rain_drops:",
        600: ":snowflake:", 601: ":snowflake:", 602: ":snowflake:", 611: ":snowflake:", 612: ":snowflake:",
        613: ":snowflake:", 615: ":snowflake:", 616: ":snowflake:", 620: ":snowflake:", 621: ":snowflake:",
        622: ":snowflake:",
        701: ":fog:", 711: ":fog:", 721: ":fog:", 731: ":fog:", 741: ":fog:", 751: ":fog:", 761: ":fog:", 762: ":fog:",
        771: ":fog:",
        781: ":cyclone:",
        800: ":sun:",
        801: ":sun_behind_small_cloud:", 802: ":sun_behind_large_cloud:", 803: ":cloud:", 804: ":cloud:",
    }
    tridash = '\n' + '---\n'

    if weather_data is False:
        return 'Err' + tridash + 'Could not get weather; Maybe check API key or location?'

    emojiweather = emoji.emojize(emoji_dict[weather_data['id']])

    color_code = get_gradient_color(weather_data['temperature'])
    emoji_t = f'{emojiweather}{weather_data["temperature"]}{weather_data["unit"]} | color={color_code}'
    condi = [x.capitalize() for x in weather_data['condition'].split(' ')]
    daily_forecast_encoded = '\nForecast:\n'
    for daily_forecast in weather_data['daily_forecast']:
        daily_forecast_encoded = f"{daily_forecast_encoded}{daily_forecast['datetime'].strftime('%a')} " \
                                 f"{daily_forecast['datetime'].month}/{daily_forecast['datetime'].day} " \
                                 f"{emoji.emojize(emoji_dict[daily_forecast['id']])} " \
                                 f"{daily_forecast['max']}{weather_data['unit']}/" \
                                 f"{daily_forecast['min']}{weather_data['unit']} | font=Menlo\n"
    return f'{emoji_t}{tridash}Condition: {" ".join(condi)}{daily_forecast_encoded}'


print(render_wx())
