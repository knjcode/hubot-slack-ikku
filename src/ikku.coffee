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
#   HUBOT_SLACK_IKKU_MSG_REDIS         - set Redis URL for cache message timestamp
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
url = require 'url'
tsRedis = require 'redis'

timezone = process.env.TZ ? ""

mecabUrl = process.env.HUBOT_SLACK_IKKU_MECAB_API_URL
if !mecabUrl
  console.error("ERROR: You should set HUBOT_SLACK_IKKU_MECAB_API_URL env variables.")

reaction = process.env.HUBOT_SLACK_IKKU_REACTION ? 'flower_playing_cards'
reaction_jiamari = process.env.HUBOT_SLACK_IKKU_JIAMARI_REACTION
reaction_jitarazu = process.env.HUBOT_SLACK_IKKU_JITARAZU_REACTION
max_jiamari = process.env.HUBOT_SLACK_IKKU_MAX_JIAMARI ? 1
max_jitarazu = process.env.HUBOT_SLACK_IKKU_MAX_JITARAZU ? 0
ikku_channel = process.env.HUBOT_SLACK_IKKU_CHANNEL ? "ikku"
tsRedisUrl = process.env.HUBOT_SLACK_IKKU_MSG_REDIS ? 'redis://localhost:6379'

info = url.parse tsRedisUrl, true
tsRedisClient = if info.auth then tsRedis.createClient(info.port, info.hostname, {no_ready_check: true}) else tsRedis.createClient(info.port, info.hostname)

module.exports = (robot) ->

  prefix = robot.adapter.client.rtm.activeTeamId + ':ikku'
  if info.auth
    tsRedisClient.auth info.auth.split(':')[1], (err) ->
      if err
        robot.logger.error "hubot-slack-ikku: Failed to authenticate to MessageRedis"
      else
        robot.logger.info "hubot-slack-ikku: Successfully authenticated to MessageRedis"

  tsRedisClient.on 'error', (err) ->
    if /ECONNREFUSED/.test then err.message else robot.logger.error err.stack

  tsRedisClient.on 'connect', ->
    robot.logger.debug "hubot-slack-ikku:  Successfully connected to MessageRedis"

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

  detectIkku = (tokens) ->
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

    return [jiamari, jitarazu]

  reactionAndCopyIkku = (channelId, messageTs, message, channelName, userName, userId, jiamari, jitarazu) ->
    robot.logger.info "Found ikku! #{message}"

    # add reactions
    addReaction(reaction, channelId, messageTs)
    .then (res) ->
      robot.logger.debug "Add recation #{reaction} ts: #{messageTs}, channel: #{channelId}, text: #{message}"
      addReaction(reaction_jiamari, channelId, messageTs) if jiamari > 0 and reaction_jiamari
      addReaction(reaction_jitarazu, channelId, messageTs) if jitarazu > 0 and reaction_jitarazu

    # copy ikku into ikku channel
    unformatted_text = "#{message} (##{channelName})"
    icon_url = robot.adapter.client.rtm.dataStore.users[userId].profile.image_48
    if icon_url is '' # set default userImage
      icon_url = 'https://i0.wp.com/slack-assets2.s3-us-west-2.amazonaws.com/8390/img/avatars/ava_0002-48.png'

    return if channelName is ikku_channel # ignore messages to ikku channel
    return if channelId[0] is 'G' # ignore private channels

    link_names = process.env.SLACK_LINK_NAMES ? 0
    postMessage(robot, ikku_channel, unformatted_text, userName, link_names, icon_url)
    .then (res) ->
      # save relation of original message ts and copied messages ts
      tsRedisClient.hsetnx "#{prefix}:#{channelId}", messageTs, res.ts
      # sum up ikku per user
      sumUpIkkuPerUser(userName)
      robot.logger.debug "Copy Ikku ts: #{messageTs}, channel: #{channelId}, text: #{message}"

  addReaction = (reaction, channelId, timestamp) -> new Promise (resolve) ->
    robot.adapter.client.web.reactions.add reaction,
      channel: channelId
      timestamp: timestamp
    , (res) -> resolve res

  removeReaction = (reaction, channelId, timestamp) -> new Promise (resolve) ->
    robot.adapter.client.web.reactions.remove reaction,
      channel: channelId
      timestamp: timestamp
    , (res) -> resolve res

  removeFormatting = (text, mode) ->
    # https://api.slack.com/docs/message-formatting
    regex = ///
      <              # opening angle bracket
      ([@#!])?       # link type
      ([^>|]+)       # link
      (?:\|          # start of |label (optional)
      ([^>]+)        # label
      )?             # end of label
      >              # closing angle bracket
    ///g

    text = text.replace regex, (m, type, link, label) ->
      switch type

        when '@'
          if label then return label
          user = robot.adapter.client.rtm.dataStore.getUserById link
          if user
            return "@#{user.name}"

        when '#'
          if label then return label
          channel = robot.adapter.client.rtm.dataStore.getChannelGroupOrDMById link
          if channel
            return "\##{channel.name}"

        when '!'
          if link in ['channel','group','everyone','here']
            return "@#{link}"

        else
          if mode is 'label'
            return label if label
          link
    text = text.replace /&lt;/g, '<'
    text = text.replace /&gt;/g, '>'
    text = text.replace /&amp;/g, '&'

  # return link if no label
  removeFormattingLabel = (text) ->
    removeFormatting(text, 'label')

  removeFormattingLink = (text) ->
    removeFormatting(text, 'link')


  robot.hear /.*?/i, (msg) ->
    if !mecabUrl
      robot.logger.error("You should set HUBOT_SLACK_IKKU_MECAB_API_URL env variables.")
      return

    unorm_text = unorm.nfkc msg.message.text

    # detect ikku
    mecabTokenize(unorm_text, robot)
    .then (result) ->
      tokens = result.word_list
      result = detectIkku(tokens)
      return unless result
      # find ikku
      jiamari = result[0]
      jitarazu = result[1]

      channelId = msg.envelope.room
      messageTs = msg.message.id
      message = msg.message.text
      channelName = robot.adapter.client.rtm.dataStore.getChannelGroupOrDMById(msg.envelope.room).name
      userName = msg.message.user.name
      userId = msg.message.user.id

      reactionAndCopyIkku(channelId, messageTs, message, channelName, userName, userId, jiamari, jitarazu)

    .catch (error) ->
      robot.logger.error error

  # change and delete ikku_channel messages and remove reactions if original message becomes not ikku
  targetChannelId = robot.adapter.client.rtm.dataStore.getChannelOrGroupByName(ikku_channel)?.id
  robot.adapter.client.rtm.on 'raw_message', (msg) ->
    msg = JSON.parse(msg)

    return if msg.type is 'message' and msg.subtype is 'bot_message' # ignore bot message

    # change messages
    if msg.type is 'message' and msg.subtype is 'message_changed'
      return if msg.message.text is msg.previous_message.text # return if text not changed

      message_channel = robot.adapter.client.rtm.dataStore.getChannelGroupOrDMById(msg.channel).name

      # changed message
      message = removeFormattingLabel msg.message.text
      unorm_text = unorm.nfkc message

      # check ikku
      mecabTokenize(unorm_text, robot)
      .then (result) ->
        tokens = result.word_list
        result = detectIkku(tokens)
        if  result is false
          # not ikku
          tsRedisClient.hget "#{prefix}:#{msg.channel}", msg.previous_message.ts, (err, reply) ->
            robot.logger.error err if err

            # delete copied ikku
            robot.adapter.client.web.chat.delete reply, targetChannelId, (err, res) ->
              robot.logger.error err if err
              robot.logger.debug "delete ikku #{JSON.stringify res}"
              tsRedisClient.hdel "#{prefix}:#{msg.channel}", msg.previous_message.ts, (err, reply) ->
                robot.logger.error err if err
                robot.logger.debug "delete redis hash #{reply}"

            # remove reactions from original message
            removeReaction(reaction, msg.channel, msg.previous_message.ts)
            removeReaction(reaction_jiamari, msg.channel, msg.previous_message.ts)
            removeReaction(reaction_jitarazu, msg.channel, msg.previous_message.ts)
        else
          # ikku
          jiamari = result[0]
          jitarazu = result[1]

          channelId = msg.channel
          messageTs = msg.previous_message.ts
          message = message
          channelName = message_channel
          userName = robot.adapter.client.rtm.dataStore.users[msg.message.user].name
          userId = msg.message.user

          reactionAndCopyIkku(channelId, messageTs, message, channelName, userName, userId, jiamari, jitarazu)

    # delete messages
    if msg.type is 'message' and msg.subtype is 'message_deleted'
      return if msg.channel is targetChannelId # return if ikku_channel messages deleted
      tsRedisClient.hget "#{prefix}:#{msg.channel}", msg.previous_message.ts, (err, reply) ->
        robot.logger.error err if err
        # delete copied ikku
        robot.adapter.client.web.chat.delete reply, targetChannelId, (err, res) ->
          robot.logger.error err if err
          robot.logger.debug "delete ikku #{JSON.stringify res}"
          tsRedisClient.hdel "#{prefix}:#{msg.channel}", msg.previous_message.ts, (err, reply) ->
            robot.logger.error err if err
            robot.logger.debug "delete redis hash #{reply}"
