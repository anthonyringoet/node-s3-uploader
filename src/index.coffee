fs        = require('fs')
extname   = require('path').extname

S3        = require('aws-sdk').S3

auto      = require('async').auto
each      = require('async').each
map       = require('async').map
retry     = require('async').retry

resize    = require 'im-resize'
metadata  = require 'im-metadata'

deprecate = require('depd') 's3-uploader'

Upload = module.exports = (awsBucketName, @opts = {}) ->
  throw new TypeError 'Bucket name can not be undefined' if not awsBucketName

  deprecate '`awsBucketRegion` is deprecated, use `aws.region` instead' if @opts.awsBucketRegion
  deprecate '`awsBucketPath` is deprecated, use `aws.path` instead' if @opts.awsBucketPath
  deprecate '`awsBucketAcl` is deprecated, use `aws.acl` instead' if @opts.awsBucketAcl
  deprecate '`awsMaxRetries` is deprecated, use `aws.maxRetries` instead' if @opts.awsMaxRetries
  deprecate '`awsHttpTimeout` is deprecated, use `aws.httpOptions.timeout` instead' if @opts.awsHttpTimeout
  deprecate '`awsAccessKeyId` is deprecated, use `aws.accessKeyId` instead' if @opts.awsAccessKeyId
  deprecate '`awsSecretAccessKey` is deprecated, use `aws.secretAccessKey` instead' if @opts.awsSecretAccessKey

  @opts.aws                     ?= {}
  @opts.aws.accessKeyId         ?= @opts.awsAccessKeyId
  @opts.aws.acl                 ?= @opts.awsBucketAcl     or 'privat'
  @opts.aws.httpOptions         ?= {}
  @opts.aws.httpOptions.timeout ?= @opts.awsHttpTimeout or 10000
  @opts.aws.maxRetries          ?= @opts.awsMaxRetries or 3
  @opts.aws.params              ?= {}
  @opts.aws.params.Bucket       = awsBucketName
  @opts.aws.path                ?= @opts.awsBucketPath    or ''
  @opts.aws.region              ?= @opts.awsBucketRegion  or 'us-east-1'
  @opts.aws.secretAccessKey     ?= @opts.awsSecretAccessKey
  @opts.aws.sslEnabled          ?= true

  @opts.cleanup                 ?= {}
  @opts.returnExif              ?= false

  @opts.resize                  ?= {}
  #@opts.resize.path
  #@opts.resize.prefix
  @opts.resize.quality          ?= 70
  @opts.versions                ?= []

  if not @opts.url and @opts.aws.region is 'us-east-1'
    @opts.url ?= "https://s3.amazonaws.com/#{@opts.aws.params.Bucket}/"
  else if not @opts.url
    @opts.url ?= "https://s3-#{@opts.aws.region}.amazonaws.com/#{@opts.aws.params.Bucket}/"

  @s3 = new S3 @opts.aws

  @

##
# Generate a random path on the form /xx/yy/zz
##
Upload.prototype._getRandomPath = ->
  input = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789'
  res = []

  for i in [1..3]
    x = input[Math.floor((Math.random() * input.length))]
    y = input[Math.floor((Math.random() * input.length))]
    res.push x + y

  return res.join '/'

##
# Generate a random avaiable path on the S3 bucket
##
Upload.prototype._getDestPath = (prefix, callback) ->
  retry 5, (cb) =>
    path = prefix + @_getRandomPath()
    @s3.listObjects Prefix: path, (err, data) ->
      return cb err if err
      return cb null, path if data.Contents.length is 0
      return cb new Error "Path #{path} not avaiable"
  , callback

##
# Upload a new image to the S3 bucket
##
Upload.prototype.upload = (src, opts, cb) ->
  image = new Image src, opts, @
  image.start(cb)

##
# Image upload
##
Image = module.exports.Image = (@src, @opts, @upload) ->
  @

Image.prototype.start = (cb) ->
  auto
    metadata: @getMetadata.bind(@, @src)
    dest: @getDest.bind(@)
    versions: ['metadata', @resizeVersions.bind(@)]
    uploads: ['versions', 'dest', @uploadVersions.bind(@)]
    cleanup: ['uploads', @removeVersions.bind(@)]
  , (err, results) ->
    cb err, results.uploads, results.metadata

##
# Get image metadata
##
Image.prototype.getMetadata = (src, cb) ->
  metadata src, exif: @upload.opts.returnExif, cb

##
# Get image destination
##
Image.prototype.getDest = (cb) ->
  prefix = @opts?.awsPath or @upload.opts.aws.path
  @upload._getDestPath prefix, cb

##
# Resize image
##
Image.prototype.resizeVersions = (cb, results) ->
  resize results.metadata,
    path: @upload.opts.resize.path
    prefix: @upload.opts.resize.prefix
    quality: @upload.opts.resize.quality
    versions: JSON.parse JSON.stringify @upload.opts.versions
  , cb

##
# Upload resized versions
##
Image.prototype.uploadVersions = (cb, results) ->
  if @upload.opts.original
    results.versions.push
      awsImageAcl: @upload.opts.original.awsImageAcl
      original: true
      path: @src

  map results.versions, @_upload.bind(@, results.dest), cb

##
# Clean up local copies
##
Image.prototype.removeVersions = (cb, results) ->
  each results.uploads, (image, callback) =>
    if not @upload.opts.cleanup.original and image.original \
      or not @upload.opts.cleanup.versions and not image.original
        return setTimeout callback, 0

    fs.unlink image.path, callback
  , (err) ->
    cb()

##
# Upload image version to S3
##
Image.prototype._upload = (dest, version, cb) ->
  format = extname version.path

  options =
    Key: dest + (version.suffix || '') + format
    ACL: version.awsImageAcl or @upload.opts.aws.acl
    Body: fs.createReadStream version.path
    ContentType: "image/#{format.substr(1)}"

  @upload.s3.putObject options, (err, data) =>
    return cb err if err

    version.etag = data.ETag
    version.key = options.Key
    version.url = @upload.opts.url + options.Key if @upload.opts.url

    cb null, version
