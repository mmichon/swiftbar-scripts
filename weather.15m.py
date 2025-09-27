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

location_name = "{0}".format(os.getenv('VAR_LOCATION')).replace(" ", "%20")

units = 'imperial'  # kelvin, metric, imperial
def get_wx():
    try:
        wx = json.load(urlopen('https://wttr.in/{0}?format=j1'.format(location_name)))
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
        for day in wx['weather']:
            daily_forecast.append({'id': day['hourly'][0]['weatherCode'],
                                   'datetime': datetime.datetime.strptime(day['date'], '%Y-%m-%d'),
                                   'max': str(int(round(float(day['maxtempF'])))) if units == 'imperial' else str(int(round(float(day['maxtempC'])))),
                                   'min': str(int(round(float(day['mintempF'])))) if units == 'imperial' else str(int(round(float(day['mintempC'])))),
                                   })
        weather_data = {
            'temperature': str(int(round(float(wx['current_condition'][0]['temp_F'])))) if units == 'imperial' else str(int(round(float(wx['current_condition'][0]['temp_C'])))),
            'condition': str(wx['current_condition'][0]['weatherDesc'][0]['value']),
            'id': int(wx['current_condition'][0]['weatherCode']),
            'city': wx['nearest_area'][0]['areaName'][0]['value'],
            'unit': '°' + unit,
            'daily_forecast': daily_forecast
        }
    except (KeyError, IndexError):
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

def get_emoji_for_weather_id(weather_id):
    if weather_id == 113:
        return ":sun:"
    elif weather_id == 116:
        return ":sun_behind_small_cloud:"
    elif weather_id == 119:
        return ":cloud:"
    elif weather_id == 122:
        return ":cloud:"
    elif weather_id == 143:
        return ":fog:"
    elif weather_id == 176:
        return ":umbrella_with_rain_drops:"
    elif weather_id == 179:
        return ":snowflake:"
    elif weather_id == 182:
        return ":snowflake:"
    elif weather_id == 185:
        return ":snowflake:"
    elif weather_id == 200:
        return ":cloud_with_lightning_and_rain:"
    elif weather_id == 227:
        return ":snowflake:"
    elif weather_id == 230:
        return ":snowflake:"
    elif weather_id == 248:
        return ":fog:"
    elif weather_id == 260:
        return ":fog:"
    elif weather_id == 263:
        return ":umbrella_with_rain_drops:"
    elif weather_id == 266:
        return ":umbrella_with_rain_drops:"
    elif weather_id == 281:
        return ":snowflake:"
    elif weather_id == 284:
        return ":snowflake:"
    elif weather_id == 293:
        return ":umbrella_with_rain_drops:"
    elif weather_id == 296:
        return ":umbrella_with_rain_drops:"
    elif weather_id == 299:
        return ":umbrella_with_rain_drops:"
    elif weather_id == 302:
        return ":umbrella_with_rain_drops:"
    elif weather_id == 305:
        return ":umbrella_with_rain_drops:"
    elif weather_id == 308:
        return ":umbrella_with_rain_drops:"
    elif weather_id == 311:
        return ":snowflake:"
    elif weather_id == 314:
        return ":snowflake:"
    elif weather_id == 317:
        return ":snowflake:"
    elif weather_id == 320:
        return ":snowflake:"
    elif weather_id == 323:
        return ":snowflake:"
    elif weather_id == 326:
        return ":snowflake:"
    elif weather_id == 329:
        return ":snowflake:"
    elif weather_id == 332:
        return ":snowflake:"
    elif weather_id == 335:
        return ":snowflake:"
    elif weather_id == 338:
        return ":snowflake:"
    elif weather_id == 350:
        return ":snowflake:"
    elif weather_id == 353:
        return ":umbrella_with_rain_drops:"
    elif weather_id == 356:
        return ":umbrella_with_rain_drops:"
    elif weather_id == 359:
        return ":umbrella_with_rain_drops:"
    elif weather_id == 362:
        return ":snowflake:"
    elif weather_id == 365:
        return ":snowflake:"
    elif weather_id == 368:
        return ":snowflake:"
    elif weather_id == 371:
        return ":snowflake:"
    elif weather_id == 374:
        return ":snowflake:"
    elif weather_id == 377:
        return ":snowflake:"
    elif weather_id == 386:
        return ":cloud_with_lightning_and_rain:"
    elif weather_id == 389:
        return ":cloud_with_lightning_and_rain:"
    elif weather_id == 392:
        return ":cloud_with_lightning_and_rain:"
    elif weather_id == 395:
        return ":cloud_with_lightning_and_rain:"
    else:
        return ""

def render_wx():
    weather_data = get_wx()
    tridash = '\n' + '---\n'
    if weather_data is False:
        return 'Err' + tridash + 'Could not get weather; Maybe check API key or location?'

    emojiweather = emoji.emojize(get_emoji_for_weather_id(weather_data['id']))

    color_code = get_gradient_color(weather_data['temperature'])
    emoji_t = '{0}{1}{2} | color={3}'.format(emojiweather, weather_data["temperature"], weather_data["unit"], color_code)
    condi = [x.capitalize() for x in weather_data['condition'].split(' ')]
    daily_forecast_encoded = '\nForecast:\n'
    for daily_forecast in weather_data['daily_forecast']:
        daily_forecast_encoded = "{0}{1} {2}/{3} {4} {5}/{6} | font=Menlo\n".format(
            daily_forecast_encoded,
            daily_forecast['datetime'].strftime('%a'),
            daily_forecast['datetime'].month,
            daily_forecast['datetime'].day,
            emoji.emojize(get_emoji_for_weather_id(daily_forecast['id'])),
            daily_forecast['max'] + weather_data['unit'],
            daily_forecast['min'] + weather_data['unit']
        )
    return '{0}{1}Condition: {2}{3}'.format(emoji_t, tridash, " ".join(condi), daily_forecast_encoded)


print(render_wx())
