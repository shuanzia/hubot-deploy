Fs        = require "fs"
Url       = require "url"
Path      = require "path"
Fernet    = require "fernet"
Version   = require(Path.join(__dirname, "..", "..", "version")).Version
Octonode  = require "octonode"
GitHubApi = require(Path.join(__dirname, "..", "api")).Api
extend    = require "node.extend"

AppsFile = process.env['HUBOT_DEPLOY_APPS_JSON'] or "apps.json"
AppsDirPath = process.env['HUBOT_DEPLOY_APPS_DIR_PATH'] or Path.resolve("./apps")
###########################################################################
readAppsConfig = () ->
  appsConfig = {}
  try
    if Fs.existsSync(AppsFile) && Fs.statSync(AppsFile).isFile()
      appsConfig = JSON.parse(Fs.readFileSync(AppsFile).toString())

    if Fs.existsSync(AppsDirPath) && Fs.statSync(AppsDirPath).isDirectory()
      for appsJSONFile in Fs.readdirSync(AppsDirPath).sort()
        if Fs.statSync(Path.join(AppsDirPath, appsJSONFile)).isFile()
          config = JSON.parse Fs.readFileSync(Path.join(AppsDirPath, appsJSONFile)).toString()
          appsConfig = extend appsConfig,config
  catch err
    throw new Error("Unable to parse your apps.json file in hubot-deploy #{err}")

  appsConfig

applications = readAppsConfig()
###########################################################################
class Deployment

  constructor: (@name, @ref, @task, @env, @force, @hosts) ->
    @room             = 'unknown'
    @user             = 'unknown'
    @adapter          = 'unknown'
    @userName         = 'unknown'
    @robotName        = 'hubot'
    @autoMerge        = true
    @environments     = [ "production" ]
    @requiredContexts = null
    @caFile           = Fs.readFileSync(process.env['HUBOT_CA_FILE']) if process.env['HUBOT_CA_FILE']

    @messageId        = undefined
    @threadId         = undefined

    @application = applications[@name]

    if @application?
      @repository = @application['repository']

      @configureAutoMerge()
      @configureRequiredContexts()
      @configureEnvironments()

      @allowedRooms = @application['allowed_rooms']

  isValidApp: ->
    @application?

  isValidEnv: ->
    @env in @environments

  isAllowedRoom: (room) ->
    !@allowedRooms? || room in @allowedRooms

  # Retrieves a fully constructed request body and removes sensitive config info
  # A hash to be converted into the body of the post to create a GitHub Deployment
  requestBody: ->
    body = JSON.parse(JSON.stringify(@unfilteredRequestBody()))
    if body?.payload?.config?
      delete(body.payload.config.github_api)
      delete(body.payload.config.github_token)
    if process.env.HUBOT_DEPLOY_ENCRYPT_PAYLOAD and process.env.HUBOT_DEPLOY_FERNET_SECRETS
      payload      = body.payload
      fernetSecret = new Fernet.Secret(process.env.HUBOT_DEPLOY_FERNET_SECRETS)
      fernetToken  = new Fernet.Token(secret: fernetSecret)

      body.payload = fernetToken.encode(payload)

    body

  unfilteredRequestBody: ->
    ref: @ref
    task: @task
    force: @force
    auto_merge: @autoMerge
    environment: @env
    required_contexts: @requiredContexts
    description: "#{@task} on #{@env} from hubot-deploy-v#{Version}"
    payload:
      name: @name
      robotName: @robotName
      hosts: @hosts
      yubikey: @yubikey
      notify:
        adapter: @adapter
        room: @room
        user: @user
        user_name: @userName
        message_id: @messageId
        thread_id: @threadId
      config: @application

  setUserToken: (token) ->
    @userToken = token.trim()

  apiConfig: ->
    new GitHubApi(@userToken, @application)

  api: ->
    api = Octonode.client(@apiConfig().token, { hostname: @apiConfig().hostname })
    api.requestDefaults.agentOptions = { ca: @caFile } if @caFile
    api

  latest: (callback) ->
    path       = @apiConfig().path("repos/#{@repository}/deployments")
    params     =
      environment: @env

    @api().get path, params, (err, status, body, headers) ->
      callback(err, body)

  post: (callback) ->
    name       = @name
    repository = @repository
    env        = @env
    ref        = @ref
    task       = @task
    hosts      = @hosts

    requiredContexts = @requiredContexts

    @rawPost (err, status, body, headers) ->
      data = body

      if err
        data = err

      success = status == 201

      if data['message']
        bodyMessage = data['message']

        if bodyMessage.match(/No successful commit statuses/)
          message = """
          I don't see a successful build for #{repository} that covers the latest \"#{ref}\" branch.
          """

        if bodyMessage.match(/Conflict merging ([-_\.0-9a-z]+)/)
          default_branch = data.message.match(/Conflict merging ([-_\.0-9a-z]+)/)[1]
          message = """
          There was a problem merging the #{default_branch} for #{repository} into #{ref}.
          You'll need to merge it manually, or disable auto-merging.
          """

        if bodyMessage.match(/Merged ([-_\.0-9a-z]+) into/)
          tmpMessage = """
          Successfully merged the default branch for #{repository} into #{ref}.
          Normal push notifications should provide feedback.
          """
          console.log tmpMessage

        if bodyMessage.match(/Conflict: Commit status checks/)
          errors = data['errors'][0]
          commitContexts = errors.contexts

          namedContexts  = (context.context for context in commitContexts )
          failedContexts = (context.context for context in commitContexts when context.state isnt 'success')
          if requiredContexts?
            failedContexts.push(context) for context in requiredContexts when context not in namedContexts

          bodyMessage = """
          Unmet required commit status contexts for #{name}: #{failedContexts.join(',')} failed.
          """

        if bodyMessage == "Not Found"
          message = "Unable to create deployments for #{repository}. Check your scopes for this token."
        else
          message = bodyMessage

      if success and not message
        message = "#{task}ing #{name}/#{ref} to #{env}"
        if hosts
          message = "#{message}/#{hosts}"

      callback(err, status, body, headers, message)

  rawPost: (callback) ->
    path       = @apiConfig().path("repos/#{@repository}/deployments")
    repository = @repository
    env        = @env
    ref        = @ref

    @api().post path, @requestBody(), (err, status, body, headers) ->
      callback(err, status, body, headers)

  # Private Methods
  configureEnvironments: ->
    if @application['environments']?
      @environments = @application['environments']

    @env = 'staging' if @env == 'stg'
    @env = 'production' if @env == 'prod'

  configureAutoMerge: ->
    if @application['auto_merge']?
      @autoMerge = @application['auto_merge']
    if @force
      @autoMerge = false

  configureRequiredContexts: ->
    if @application['required_contexts']?
      @requiredContexts = @application['required_contexts']
    if @force
      @requiredContexts = [ ]

exports.Deployment = Deployment
