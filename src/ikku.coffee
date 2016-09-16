# Description
#   Add reaction to ultrasoul messages
#
# Configuration:
#   HUBOT_SLACK_IKKU_CHANNEL           - ikku channel name (defualt. ikku)
#   HUBOT_SLACK_IKKU_JIAMARI_REACTION  - set jiamari emoji
#   HUBOT_SLACK_IKKU_JITARAZU_REACTION - set jitarazu emoji
#   HUBOT_SLACK_IKKU_RANKING_CHANNEL   - ranking channel name (default. ikku)
#   HUBOT_SLACK_IKKU_RANKING_CRONJOB   - ranking cron (default. "0 0 10 * * *")
#   HUBOT_SLACK_IKKU_RANKING_ENABLED   - set 1 to display ranking
#   HUBOT_SLACK_IKKU_MAX_JIAMARI       - set max jiamari (default. 1)
#   HUBOT_SLACK_IKKU_MAX_JITARAZU      - set max jitarazu (defualt. 0)
#   HUBOT_SLACK_IKKU_MECAB_API_URL     - set mecab-api URL
#   HUBOT_SLACK_IKKU_REACTION          - set reaction emoji (default. flower_playing_cards)
#   SLACK_LINK_NAMES                   - set 1 to enable link names in ikku channel
#   TZ                                 - set timezone
#
# Reference
#   https://github.com/hakatashi/slack-ikku
#
# Author:
#   knjcode <knjcode@gmail.com>

{Promise} = require 'es6-promise'

cloneDeep = require 'lodash.clonedeep'
cronJob = require('cron').CronJob
max = require 'lodash.max'
reduce = require 'lodash.reduce'
tokenize = require 'kuromojin'
unorm = require 'unorm'
util = require 'util'
zipWith = require 'lodash.zipwith'

timezone = process.env.TZ ? ""

mecabUrl = process.env.HUBOT_SLACK_IKKU_MECAB_API_URL
if !mecabUrl
  console.error("ERROR: You should set HUBOT_SLACK_IKKU_MECAB_API_URL env variables.")

reaction = process.env.HUBOT_SLACK_IKKU_REACTION ? 'flower_playing_cards'
reaction_jiamari = process.env.HUBOT_SLACK_IKKU_JIAMARI_REACTION
reaction_jitarazu = process.env.HUBOT_SLACK_IKKU_JITARAZU_REACTION
max_jiamari = process.env.HUBOT_SLACK_IKKU_MAX_JIAMARI ? 1
max_jitarazu = process.env.HUBOT_SLACK_IKKU_MAX_JITARAZU ? 0

module.exports = (robot) ->

  data = {}
  latestData = {}
  report = []
  loaded = false

  robot.brain.on "loaded", ->
    # "loaded" event is called every time robot.brain changed
    # data loading is needed only once after a reboot
    if !loaded
      try
        data = JSON.parse robot.brain.data.ikkuSumup
        latestData = JSON.parse robot.brain.data.ikkuSumupLatest
      catch error
        robot.logger.info("JSON parse error (reason: #{error})")
      enableReport()
    loaded = true

  checkArrayDifference = (a, b) ->
    tmp = zipWith a, b, (x, y) ->
      x - y
    .map (x) -> max [x, 0]
    reduce tmp, (sum, n) -> sum + n


  postMessage = (robot, channel_name, unformatted_text, user_name, link_names, icon_url) -> new Promise (resolve) ->
    robot.adapter.client.web.chat.postMessage channel_name, unformatted_text,
      username: user_name
      link_names: link_names
      icon_url: icon_url
    , (err, res) ->
      if err
        robot.logger.error err
      resolve res

  sumUpIkkuPerUser = (user_name) ->
    if !data
      data = {}
    if !data[user_name]
      data[user_name] = 0
    data[user_name]++
    # wait robot.brain.set until loaded avoid destruction of data
    if loaded
      robot.brain.data.ikkuSumup = JSON.stringify data

  score = ->
    # culculate diff between data and latestData
    diff = {}
    for key, value of data
      if !latestData[key]
        latestData[key] = 0
      if (value - latestData[key]) > 0
        diff[key] = value - latestData[key]
    # sort diff by value
    z = []
    for key,value of diff
      z.push([key,value])
    z.sort( (a,b) -> b[1] - a[1] )
    # display ranking
    if z.length > 0
      msgs = [ "ここ一日の詠み人" ]
      top5 = z[0..4]
      for ikkuPerUser in top5
        msgs.push(ikkuPerUser[0]+" ("+ikkuPerUser[1]+"句)")
      return msgs.join("\n")
    return ""

  display_ranking = ->
    ranking_enabled = process.env.HUBOT_SLACK_IKKU_RANKING_ENABLED
    if ranking_enabled
      hubot_name = robot.adapter.self.name
      icon_url = robot.brain.data.userImages[robot.adapter.self.id]
      link_names = process.env.SLACK_LINK_NAMES ? 0
      ranking_channel = process.env.HUBOT_SLACK_IKKU_RANKING_CHANNEL ? "ikku"
      ranking_text = score()
      if ranking_text.length > 0
        postMessage(robot, ranking_channel, ranking_text, hubot_name, link_names, icon_url)
        .then (result) ->
          robot.logger.info "post ranking: #{JSON.stringify result}"
          # update latestData
          latestData = cloneDeep data
          robot.brain.data.ikkuSumupLatest = JSON.stringify latestData

  enableReport = ->
    ranking_enabled = process.env.HUBOT_SLACK_IKKU_RANKING_ENABLED
    if ranking_enabled
      for job in report
        job.stop()
      report = []
      ranking_cronjob = process.env.HUBOT_SLACK_IKKU_RANKING_CRONJOB ? "0 0 10 * * *"
      report[report.length] = new cronJob ranking_cronjob, () ->
        display_ranking()
      , null, true, timezone
      robot.logger.info("hubot-slack-ikku: set ranking cronjob at " + ranking_cronjob)

  mecabTokenize = (unorm_text, robot) -> new Promise (resolve) ->
    json = JSON.stringify {
      "sentence": unorm_text
      "dictionary": 'mecab-ipadic-neologd'
    }
    robot.http(mecabUrl)
      .header("Content-type", "application/json")
      .post(json) (err, res, body) ->
        resolve JSON.parse(body)

  isIkku = (message) ->
    if !mecabUrl
      robot.logger.error("You should set HUBOT_SLACK_IKKU_MECAB_API_URL env variables.")
      return false
    unorm_text = unorm.nfkc message

    # detect ikku
    mecabTokenize(unorm_text, robot)
    .then (result) ->
      tokens = result.word_list
      targetRegions = [5, 7, 5]
      regions = [0]

      `outer://`
      for token in tokens
        continue if token.pos is '記号'
        for item in ['、', '!', '?']
          if token.surface_form is item
            if regions[regions.length - 1] isnt 0
              regions.push 0
            `continue outer`

        pronunciation = token.pronunciation or token.surface_form
        return false unless pronunciation.match /^[ぁ-ゔァ-ヺー…]+$/

        regionLength = pronunciation.replace(/[ぁぃぅぇぉゃゅょァィゥェォャュョ…]/g, '').length

        if ((token.pos) is '助詞' or (token.pos) is '助動詞') or ((token.pos_detail_1) is '接尾' or (token.pos_detail_1) is '非自立')
          regions[regions.length - 1] += regionLength
        else if (regions[regions.length - 1] < targetRegions[regions.length - 1] or regions.length is 3)
          regions[regions.length - 1] += regionLength
        else
          regions.push(regionLength)

      if regions[regions.length - 1] is 0
        regions.pop

      return false if regions.length isnt targetRegions.length

      jiamari = checkArrayDifference regions, targetRegions
      jitarazu = checkArrayDifference targetRegions, regions

      return false if jitarazu > max_jitarazu or jiamari > max_jiamari

      return true


  robot.hear /.*?/i, (msg) ->
    if isIkku(msg.message.text)
      # find ikku

      # addReaction
      robot.adapter.client.web.reactions.add reaction,
        channel: msg.envelope.room
        timestamp: msg.message.id
      .then (res) ->
        robot.logger.info "Found ikku! #{msg.message.text}"
        robot.logger.debug "Add recation #{reaction} ts: #{msg.message.id}, channel: #{msg.envelope.room}, text: #{msg.message.text}"
        addReaction(reaction_jiamari, msg) if jiamari > 0 and reaction_jiamari
        addReaction(reaction_jitarazu, msg) if jitarazu > 0 and reaction_jitarazu
      .catch (error) ->
        robot.logger.error error

      # copyMessage
      channel_name = robot.adapter.client.rtm.dataStore.getChannelGroupOrDMById(msg.envelope.room).name
      unformatted_text = "#{msg.message.text} (##{channel_name})"
      user_name = msg.message.user.name
      icon_url = robot.adapter.client.rtm.dataStore.users[msg.message.user.id].profile.image_48
      if icon_url is '' # set default userImage
        icon_url = 'https://i0.wp.com/slack-assets2.s3-us-west-2.amazonaws.com/8390/img/avatars/ava_0002-48.png'

      link_names = process.env.SLACK_LINK_NAMES ? 0
      ikku_channel = process.env.HUBOT_SLACK_IKKU_CHANNEL ? "ikku"

      # ignore messages to ikku channel
      return if channel_name is ikku_channel

      # ignore private channels
      return if msg.envelope.room[0] is 'G'

      if icon_url is ''
        icon_url = 'https://i0.wp.com/slack-assets2.s3-us-west-2.amazonaws.com/8390/img/avatars/ava_0002-48.png'
      postMessage(robot, ikku_channel, unformatted_text, user_name, link_names, icon_url)
      .then ->
        sumUpIkkuPerUser(user_name)
        robot.logger.debug "Copy Ikku ts: #{msg.message.id}, channel: #{msg.envelope.room}, text: #{msg.message.text}"

    .catch (error) ->
      robot.logger.error error
