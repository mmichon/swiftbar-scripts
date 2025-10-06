#!/usr/bin/env python3

# <xbar.title>Weather - wttr.in</xbar.title>
# <xbar.version>v2.0</xbar.version>
# <xbar.author>Daniel Seripap</xbar.author>
# <xbar.author.github>seripap</xbar.author.github>
# <xbar.desc>Grabs simple weather information from wttr.in. No API key required.</xbar.desc>
# <xbar.image>https://poolis.github.io/bitbar-plugins/open-weather-preview.png</xbar.image>
# <xbar.dependencies>python,emoji</xbar.dependencies>

import emoji
import json
from urllib.request import urlopen
from urllib.error import URLError
from random import randint
import datetime
import os
from urllib.parse import quote

units = 'imperial'  # 'metric' for Celsius, 'imperial' for Fahrenheit
lang = 'en'

def get_location():
    try:
        response = urlopen('http://ipinfo.io/json')
        data = json.load(response)
        return data['city']
    except Exception:
        return None

def get_wx():
    city = get_location()
    if city:
        city_encoded = quote(city)
        url = f'http://wttr.in/{city_encoded}?format=j1&lang={lang}'
    else:
        url = f'http://wttr.in/?format=j1&lang={lang}'
    try:
        response = urlopen(url)
        wx = json.load(response)
    except (URLError, json.JSONDecodeError):
        return False

    if units == 'metric':
        hourly_temp_unit = 'tempC'
        current_temp_unit = 'temp_C'
        maxtemp_unit = 'maxtempC'
        mintemp_unit = 'mintempC'
        unit_symbol = 'C'
    else: # imperial
        hourly_temp_unit = 'tempF'
        current_temp_unit = 'temp_F'
        maxtemp_unit = 'maxtempF'
        mintemp_unit = 'mintempF'
        unit_symbol = 'F'

    try:
        now = datetime.datetime.now()
        current_day_forecast = wx['weather'][0] # Today's forecast
        current_hour_forecast = None
        for hourly_forecast in reversed(current_day_forecast['hourly']):
            if int(hourly_forecast['time']) // 100 <= now.hour:
                current_hour_forecast = hourly_forecast
                break

        if current_hour_forecast:
            temp_to_use = current_hour_forecast[hourly_temp_unit]
        else:
            # Fallback to current_condition if hourly forecast for current hour is not available
            temp_to_use = wx['current_condition'][0][current_temp_unit]

        daily_forecast = []
        for day in wx['weather']:
            daily_forecast.append({
                'id': int(day['hourly'][0]['weatherCode']),
                'datetime': datetime.datetime.strptime(day['date'], '%Y-%m-%d'),
                'max': day[maxtemp_unit],
                'min': day[mintemp_unit]
            })

        weather_data = {
            'temperature': temp_to_use,
            'condition': wx['current_condition'][0]['weatherDesc'][0]['value'],
            'id': int(wx['current_condition'][0]['weatherCode']),
            'city': wx['nearest_area'][0]['areaName'][0]['value'],
            'unit': '°' + unit_symbol,
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

def render_wx():
    weather_data = get_wx()
    # Weather codes from https://www.worldweatheronline.com/weather-api/api/docs/weather-icons.aspx
    emoji_dict = {
        113: ":sun:",  # Sunny
        116: ":sun_behind_small_cloud:",  # Partly cloudy
        119: ":cloud:",  # Cloudy
        122: ":cloud:",  # Overcast
        143: ":fog:",  # Mist
        176: ":cloud_with_rain:",  # Patchy rain possible
        179: ":cloud_with_snow:",  # Patchy snow possible
        182: ":cloud_with_sleet:",  # Patchy sleet possible
        185: ":cloud_with_rain:",  # Patchy freezing drizzle possible
        200: ":cloud_with_lightning_and_rain:",  # Thundery outbreaks possible
        227: ":cloud_with_snow:",  # Blowing snow
        230: ":snowflake:",  # Blizzard
        248: ":fog:",  # Fog
        260: ":fog:",  # Freezing fog
        263: ":cloud_with_rain:",  # Patchy light drizzle
        266: ":cloud_with_rain:",  # Light drizzle
        281: ":cloud_with_rain:",  # Freezing drizzle
        284: ":cloud_with_rain:",  # Heavy freezing drizzle
        293: ":cloud_with_rain:",  # Patchy light rain
        296: ":cloud_with_rain:",  # Light rain
        299: ":cloud_with_rain:",  # Moderate rain at times
        302: ":cloud_with_rain:",  # Moderate rain
        305: ":cloud_with_rain:",  # Heavy rain at times
        308: ":cloud_with_rain:",  # Heavy rain
        311: ":cloud_with_rain:",  # Light freezing rain
        314: ":cloud_with_rain:",  # Moderate or heavy freezing rain
        317: ":cloud_with_sleet:",  # Light sleet
        320: ":cloud_with_sleet:",  # Moderate or heavy sleet
        323: ":cloud_with_snow:",  # Patchy light snow
        326: ":cloud_with_snow:",  # Light snow
        329: ":cloud_with_snow:",  # Patchy moderate snow
        332: ":cloud_with_snow:",  # Moderate snow
        335: ":cloud_with_snow:",  # Patchy heavy snow
        338: ":cloud_with_snow:",  # Heavy snow
        350: ":ice:",  # Ice pellets
        353: ":cloud_with_rain:",  # Light rain shower
        356: ":cloud_with_rain:",  # Moderate or heavy rain shower
        359: ":cloud_with_rain:",  # Torrential rain shower
        362: ":cloud_with_sleet:",  # Light sleet showers
        365: ":cloud_with_sleet:",  # Moderate or heavy sleet showers
        368: ":cloud_with_snow:",  # Light snow showers
        371: ":cloud_with_snow:",  # Moderate or heavy snow showers
        374: ":ice:",  # Light showers of ice pellets
        377: ":ice:",  # Moderate or heavy showers of ice pellets
        386: ":cloud_with_lightning_and_rain:",  # Patchy light rain with thunder
        389: ":cloud_with_lightning_and_rain:",  # Moderate or heavy rain with thunder
        392: ":cloud_with_lightning_and_snow:",  # Patchy light snow with thunder
        395: ":cloud_with_lightning_and_snow:",  # Moderate or heavy snow with thunder
    }
    tridash = '\n' + '---\n'

    if weather_data is False:
        return 'Err' + tridash + 'Could not get weather.'

    emojiweather = emoji.emojize(emoji_dict.get(weather_data['id'], ":question_mark:"))

    color_code = get_gradient_color(weather_data['temperature'])
    emoji_t = f'{emojiweather}{weather_data["temperature"]}{weather_data["unit"]} | color={color_code}'
    condi = [x.capitalize() for x in weather_data['condition'].split(' ')]
    daily_forecast_encoded = '\nForecast:\n'
    for daily_forecast in weather_data['daily_forecast']:
        daily_forecast_encoded = f"{daily_forecast_encoded}{daily_forecast['datetime'].strftime('%a')} " \
                                 f"{daily_forecast['datetime'].month}/{daily_forecast['datetime'].day} " \
                                 f"{emoji.emojize(emoji_dict.get(daily_forecast['id'], ':question_mark:'))} " \
                                 f"{daily_forecast['max']}{weather_data['unit']}/" \
                                 f"{daily_forecast['min']}{weather_data['unit']} | font=Menlo\n"
    return f'{emoji_t}{tridash}Condition: {" ".join(condi)}{daily_forecast_encoded}'


print(render_wx())
