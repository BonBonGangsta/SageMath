FROM sagemath/sagemath
#RUN sage -pip install notebook

WORKDIR /app

ENTRYPOINT ["bash"]
# CMD ["sage", "-n", "jupyter", "--ip=0.0.0.0", "--port=8888", "--no-browser"]