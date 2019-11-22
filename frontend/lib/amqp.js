'use strict'

const rhea = require('rhea')
const { AMQP: AMQP_CONFIG, NODE_ENV } = require('./config')
const crypto = require('crypto')
const log = require('./log')

// When not running in production allow AMQP to be a no-op
const AMQP_NOOP = NODE_ENV !== 'production' && !AMQP_CONFIG.HOST
const id = 'frontend-nodejs-' + crypto.randomBytes(2).toString('hex')

log.info(`creating AMQP connection with ID: ${id}`)
const container = rhea.create_container({ id })

let connection
let requestSequence = 0

container.on('connection_open', event => {
  log.info(`${id}: Connected to AMQP messaging service at ${AMQP_CONFIG.HOST}:${AMQP_CONFIG.PORT}`)
  connection = event.connection
})

container.on('error', err => {
  log.error(err)
  log.error('Exiting worker with status 100')
  process.exit(100)
})

log.info(`${id}: Attempting to connect to AMQP messaging service at ${AMQP_CONFIG.HOST}:${AMQP_CONFIG.PORT}`)
container.connect({
  host: AMQP_CONFIG.HOST,
  port: AMQP_CONFIG.PORT,
  username: AMQP_CONFIG.USER,
  password: AMQP_CONFIG.PASSWORD
})

/**
 * Send a message to the queue
 * @param {Object} body
 */
exports.sendMessage = function (body) {
  const messageId = id + '/' + requestSequence++
  const message = {
    to: 'work-queue-requests',
    message_id: messageId,
    body: JSON.stringify({ ...body, message_id: messageId })
  }

  log.debug(`${id}: constructed message for sending: %j`, message)

  if (!connection) {
    if (!AMQP_NOOP) {
      log.warn(`${id}: AMQP is not connected but an attempt was made to send a message`)
      return Promise.reject(new Error('AMQP connection is not ready/available'))
    } else {
      log.warn(`${id}: In development mode and AMQP connection environment variables were not set. AQMP noop for message - ${JSON.stringify(message)}`)
      return Promise.resolve(message.message_id)
    }
  } else {
    log.info(`${id}: Sending request ${JSON.stringify(message)}`)

    connection.send(message)

    return Promise.resolve(message.message_id)
  }
}
