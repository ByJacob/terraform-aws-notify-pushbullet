from __future__ import print_function

import json
import logging
import os
import urllib.parse
import urllib.request
from urllib.error import HTTPError


def notify_pushbullet(subject, message, arn):
    api_keys = json.loads(os.environ['PUSHBULLET_API_KEYS'])

    reason = message
    change_state = ""
    if type(message) is str:
        try:
            message = json.loads(message)
        except json.JSONDecodeError as err:
            logging.exception(f'JSON decode error: {err}')

    title = "AWS CW - " + arn
    if "NewStateReason" in message:
        reason = message["NewStateReason"]
        if "OldStateValue" in message:
            change_state = f"State {message['OldStateValue']}->{message['NewStateValue']}:\n"
    if "AlarmName" in message:
        title = "AWS CW - " + message["AlarmName"]

    payload = {
        "type": "note",
        "title": title,
        "body": f"{change_state}{reason}"
    }

    results = {"code": 0, "info_list": []}

    for user, api_key in api_keys.items():
        headers = {
            "Access-Token": api_key
        }

        data = urllib.parse.urlencode(payload).encode("utf-8")
        req = urllib.request.Request("https://api.pushbullet.com/v2/pushes", headers=headers)

        try:
            result = urllib.request.urlopen(req, data)
            status_code = result.getcode()
            if results["code"] < status_code:
                results["code"] = status_code
            results["info_list"].append({"user": user, "code": status_code, "info": result.info().as_string()})

        except HTTPError as e:
            logging.error("{}: result".format(e))
            status_code = e.getcode()
            if results["code"] < status_code:
                results["code"] = status_code
            results["info_list"].append({"user": user, "code": status_code, "info": e.info().as_string()})
    return results


def lambda_handler(event, context):
    if 'LOG_EVENTS' in os.environ and os.environ['LOG_EVENTS'] == 'True':
        logging.warning('Event logging enabled: `{}`'.format(json.dumps(event)))

    subject = event['Records'][0]['Sns']['Subject']
    message = event['Records'][0]['Sns']['Message']
    arn = event['Records'][0]['Sns']['TopicArn']
    response = notify_pushbullet(subject, message, arn)

    if response["code"] != 200:
        logging.error(
            "Error: received status `{}` using event `{}` and context `{}`".format(json.dumps(response), event,
                                                                                   context))

    return response
