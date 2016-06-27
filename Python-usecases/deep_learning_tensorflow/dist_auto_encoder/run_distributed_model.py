'''
Created on Jun 2, 2016

@author: minhtran
'''
import tensorflow as tf
from encoder import AutoEncoder
from configuration import Config
import numpy as np

# Flags for defining the tf.train.ClusterSpec
tf.app.flags.DEFINE_string("ps_hosts", "",
                           "Comma-separated list of hostname:port pairs")
tf.app.flags.DEFINE_string("worker_hosts", "",
                           "Comma-separated list of hostname:port pairs")

# Flags for defining the tf.train.Server
tf.app.flags.DEFINE_string("job_name", "", "One of 'ps', 'worker'")
tf.app.flags.DEFINE_integer("task_index", 0, "Index of task within the job")

FLAGS = tf.app.flags.FLAGS

def average_gradients(tower_grads):
    """Calculate the average gradient for each shared variable.
    """
    average_grads = []
    for grad_and_vars in zip(*tower_grads):
        grads = []
        for g, _ in grad_and_vars:
            expanded_g = tf.expand_dims(g, 0)
            grads.append(expanded_g)
        # Average over the 'tower' dimension.
        grad = tf.concat(0, grads)
        grad = tf.reduce_mean(grad, 0)
        v = grad_and_vars[0][1]
        grad_and_var = (grad, v)
        average_grads.append(grad_and_var)
    return average_grads 

# The main function                            
def main(_):
    # Load configuration
    config = Config()

    # Get ps and worker servers
    ps_hosts = FLAGS.ps_hosts.split(",")
    worker_hosts = FLAGS.worker_hosts.split(",")

    # Create a cluster from the parameter server and worker hosts
    cluster = tf.train.ClusterSpec({"ps": ps_hosts, "worker": worker_hosts})
    
    # Create and start a server for the local task
    server = tf.train.Server(cluster, job_name=FLAGS.job_name, task_index=FLAGS.task_index)
    
    if FLAGS.job_name == "ps":
        # Initialize the autoencoders
        autoEncoder = [None for _ in range(len(worker_hosts))]
        
        # Build the graph and run
        with tf.Graph().as_default(), tf.Session(server.target) as sess:
            # Initialize grads, mse and embeddings
            total_grads, total_mse, embeddings = [], tf.constant(0.0), None
            
            # Build the optimizer
            optimizer = tf.train.AdamOptimizer(config.learning_rate)
            
            # Build sub-graphs for each worker
            for worker in range(len(worker_hosts)):
                with tf.device(tf.train.replica_device_setter(worker_device="/job:worker/task:%d" 
                                                              % worker, cluster=cluster)): 
                    # Build a sub-graph
                    autoEncoder[worker] = AutoEncoder(config, embeddings=embeddings)
                    if worker > 0: tf.get_variable_scope().reuse_variables()
                    autoEncoder[worker].build_dist_model(optimizer, worker=worker)
                    
                    # Accumulate grads and mse
                    total_grads.append(autoEncoder[worker].get_grads())
                    total_mse += autoEncoder[worker].get_mse() / len(worker_hosts)
                
                    # Get embeddings
                    embeddings = autoEncoder[worker].get_embeddings()

            # Define the norm_grads
            norm_grads = average_gradients(total_grads)     
        
            # Define a training step
            train_step = optimizer.apply_gradients(norm_grads)

            # Run initializations
            sess.run(tf.initialize_all_variables())
                             
            # Run epochs
            for epoch in range(config.num_epoch):
                while_break, mseList = False, []
                with open(config.data_path, 'r') as data_file:
                    while True:
                        feed_dict = dict()
                        for worker in range(len(worker_hosts)):
                            inputs, outputs, states, _ = autoEncoder[worker].get_batch(data_file)
                            if inputs is None: 
                                while_break = True
                                break

                            # Create feed_dict
                            feed_dict[autoEncoder[worker].get_input_batch()] = inputs
                            feed_dict[autoEncoder[worker].get_output_batch()] = outputs
                            feed_dict[autoEncoder[worker].get_initial_state()] = states
                        
                        # Break if there is none of batches
                        if while_break: break           
                        
                        # Run parallel for batches
                        [_, mse] = sess.run([train_step, total_mse], feed_dict=feed_dict)

                        # Accumulate mse
                        mseList.append(mse)
                
                if epoch % 1 == 0:
                    print ('Epoch %d has mean square error: %g' % (epoch, np.mean(mseList)))                        
    
                # Store the model
                saver = tf.train.Saver(tf.all_variables())
                saver.save(sess, config.save_path)
        
    elif FLAGS.job_name == "worker":
        server.join()

# The main method
if __name__ == "__main__":
    tf.app.run()
    
    
    